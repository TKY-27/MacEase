#!/usr/bin/env python3
"""Build the pinned Core ML upscaler."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import urllib.request


ROOT = Path(__file__).resolve().parent.parent
LOCK = ROOT / "Vendor/upscaler.lock"
OUTPUT = ROOT / "Vendor/build/upscaler"
MODEL_NAME = "Swin2SR.mlmodelc"
REPOSITORY = "caidas/swin2SR-classical-sr-x2-64"
LICENSE_URL = "https://www.apache.org/licenses/LICENSE-2.0.txt"
TILE_EDGE = 64
SCALE = 2
REFERENCE_SEED = 4521
MAXIMUM_MEAN_ERROR = 0.1
MAXIMUM_CHANNEL_ERROR = 2


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def entries() -> tuple[str, dict[str, str], list[str]]:
    revision = ""
    artifacts = {}
    requirements = []
    for line in LOCK.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        if line.startswith("revision "):
            revision = line.split()[1]
        elif "==" in line:
            requirements.append(line)
        else:
            name, checksum = line.split()
            artifacts[name] = checksum
    if not revision or not requirements:
        raise RuntimeError("Incomplete upscaler lock")
    return revision, artifacts, requirements


def verify_environment(requirements: list[str]) -> None:
    from importlib.metadata import version

    for entry in requirements:
        name, required = entry.split("==")
        installed = version(name)
        if installed != required:
            raise RuntimeError(f"Build dependency {name}: expected {required}, found {installed}")


def sources(revision: str, artifacts: dict[str, str], directory: Path) -> None:
    from huggingface_hub import hf_hub_download

    for name, expected in artifacts.items():
        if name == "LICENSE-2.0.txt":
            destination = directory / name
            with urllib.request.urlopen(LICENSE_URL, timeout=30) as response:
                destination.write_bytes(response.read())
        else:
            cached = hf_hub_download(repo_id=REPOSITORY, filename=name, revision=revision)
            destination = directory / name
            shutil.copyfile(cached, destination)
        if digest(destination) != expected:
            raise RuntimeError(f"SHA-256 mismatch: {name}")
    if (directory / "model.safetensors").stat().st_size != 48_460_660:
        raise RuntimeError("Model weight size mismatch")


def convert(directory: Path, package: Path) -> torch.nn.Module:
    import coremltools as ct
    import torch
    from transformers import Swin2SRForImageSuperResolution

    class Upscale(torch.nn.Module):
        def __init__(self, model: torch.nn.Module):
            super().__init__()
            self.model = model

        def forward(self, pixel_values: torch.Tensor) -> torch.Tensor:
            return self.model(pixel_values=pixel_values).reconstruction * 255

    torch.set_num_threads(4)
    model = Upscale(Swin2SRForImageSuperResolution.from_pretrained(directory, local_files_only=True).eval())
    model.eval()
    example = torch.zeros(1, 3, TILE_EDGE, TILE_EDGE)
    traced = torch.jit.trace(model, example, check_trace=False)
    coreml = ct.convert(
        traced,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS26,
        inputs=[ct.ImageType(name="pixel_values", shape=example.shape, scale=1 / 255, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.ImageType(name="reconstruction", color_layout=ct.colorlayout.RGB)],
        compute_precision=ct.precision.FLOAT32,
    )
    coreml.author = "Swin2SR model by Conde et al.; Core ML conversion by MacEase"
    coreml.license = "Apache-2.0"
    coreml.short_description = "Fixed 64 x 64 RGB tile, 2x image super-resolution"
    coreml.save(str(package))
    return model


def check_output(model: torch.nn.Module, package: Path) -> None:
    import coremltools as ct
    import numpy as np
    from PIL import Image
    import torch

    rng = np.random.default_rng(REFERENCE_SEED)
    source = rng.integers(0, 256, (TILE_EDGE, TILE_EDGE, 3), dtype=np.uint8)
    tensor = torch.from_numpy(source.transpose(2, 0, 1).copy()).unsqueeze(0).float() / 255
    with torch.no_grad():
        expected = model(tensor).squeeze(0).permute(1, 2, 0).numpy()
    expected = np.clip(np.rint(expected), 0, 255).astype(np.uint8)
    converted = ct.models.MLModel(str(package), compute_units=ct.ComputeUnit.CPU_ONLY)
    actual = np.asarray(converted.predict({"pixel_values": Image.fromarray(source, "RGB")})["reconstruction"])[..., :3]
    if actual.shape != (TILE_EDGE * SCALE, TILE_EDGE * SCALE, 3):
        raise RuntimeError(f"Unexpected Core ML output shape: {actual.shape}")
    difference = np.abs(actual.astype(np.int16) - expected.astype(np.int16))
    mean_error = float(difference.mean())
    maximum_error = int(difference.max())
    print(f"Core ML vs PyTorch: mean {mean_error:.6f}, maximum {maximum_error} / 255")
    if mean_error > MAXIMUM_MEAN_ERROR or maximum_error > MAXIMUM_CHANNEL_ERROR:
        raise RuntimeError("Core ML numerical check failed")


def manifest(directory: Path) -> str:
    return "\n".join(
        f"{digest(path)}  {path.relative_to(directory)}"
        for path in sorted(directory.rglob("*")) if path.is_file() and path.name != ".manifest"
    ) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--verify-only", action="store_true")
    options = parser.parse_args()
    revision, artifacts, requirements = entries()
    stamp = hashlib.sha256((digest(LOCK) + digest(Path(__file__))).encode()).hexdigest()
    stamp_file = OUTPUT / ".stamp"
    manifest_file = OUTPUT / ".manifest"
    if not options.force and stamp_file.is_file() and manifest_file.is_file() and (OUTPUT / MODEL_NAME).is_dir():
        if stamp_file.read_text().strip() == stamp and manifest_file.read_text() == manifest(OUTPUT):
            print("Upscaler is up to date.")
            return
    if options.verify_only:
        raise SystemExit(1)
    verify_environment(requirements)
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="macease-upscaler-") as work:
        working = Path(work)
        source = working / "source"
        source.mkdir()
        sources(revision, artifacts, source)
        package = working / "Swin2SR.mlpackage"
        model = convert(source, package)
        check_output(model, package)
        release = working / "upscaler"
        release.mkdir()
        subprocess.run(["xcrun", "coremlcompiler", "compile", str(package), str(release)], check=True)
        shutil.copyfile(source / "README.md", release / "MODEL_CARD.md")
        shutil.copyfile(source / "LICENSE-2.0.txt", release / "LICENSE-2.0.txt")
        (release / ".stamp").write_text(stamp + "\n")
        (release / ".manifest").write_text(manifest(release))
        if OUTPUT.exists():
            shutil.rmtree(OUTPUT)
        shutil.move(str(release), str(OUTPUT))
    print(f"Built {OUTPUT / MODEL_NAME}")


if __name__ == "__main__":
    main()
