#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys


MACHO_HEADERS = {bytes.fromhex(header) for header in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe",
    "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
)}
LIBRARY_VALIDATION = {"com.apple.security.cs.disable-library-validation": True}


def binaries(code_path):
    for binary in sorted(code_path.rglob("*") if code_path.is_dir() else [code_path]):
        if binary.is_symlink() or not binary.is_file():
            continue
        with binary.open("rb") as source:
            if source.read(4) in MACHO_HEADERS:
                yield binary


def expected_entitlements(binary, configuration):
    if binary.parent.name == "MacOS":
        if binary.name in ("MacEase", "MacEase Dev"):
            expected = {"com.apple.security.automation.apple-events": True}
        elif binary.name == "MacEaseFinderSync":
            folder = "MacEase Dev" if configuration == "Debug" else "MacEase"
            expected = {
                "com.apple.security.app-sandbox": True,
                "com.apple.security.temporary-exception.files.home-relative-path.read-only":
                    [f"/Library/Application Support/{folder}/"],
            }
        else:
            return {}
        if configuration == "Debug":
            expected["com.apple.security.get-task-allow"] = True
        return expected
    if binary.parent.name == "bin":
        if binary.parent.parent.name == "media-tools":
            if binary.name in ("ffmpeg", "ffprobe") or re.fullmatch(r"python3\.\d+", binary.name):
                return LIBRARY_VALIDATION
        if binary.parent.parent.name == "ai-audio" and binary.name in (
            "sherpa-onnx-offline-denoiser", "sherpa-onnx-offline-source-separation",
        ):
            return LIBRARY_VALIDATION
    return {}


def verify(binary, configuration, adhoc):
    signature = subprocess.run(
        ["codesign", "-d", "--verbose=4", "--entitlements", "-", "--xml", str(binary)],
        check=True, capture_output=True, text=True,
    )
    flags = next(line for line in signature.stderr.splitlines() if line.startswith("CodeDirectory "))
    if "runtime" not in flags:
        raise ValueError(f"Hardened Runtime missing: {binary}")
    if adhoc and "Signature=adhoc" not in signature.stderr:
        raise ValueError(f"Expected ad-hoc signature: {binary}")
    entitlements = plistlib.loads(signature.stdout.encode()) if signature.stdout.strip() else {}
    expected = expected_entitlements(binary, configuration)
    if plistlib.dumps(entitlements) != plistlib.dumps(expected):
        raise ValueError(f"Unexpected entitlements: {binary}: {entitlements}; expected {expected}")
    subprocess.run(["codesign", "--verify", "--strict", str(binary)], check=True, capture_output=True, text=True)
    return flags, entitlements


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("code_path", type=Path)
    parser.add_argument("--configuration", choices=("Debug", "Release"), default="Release")
    parser.add_argument("--adhoc", action="store_true")
    parser.add_argument("--quiet", action="store_true")
    options = parser.parse_args()
    if not options.code_path.exists():
        raise ValueError(f"Missing bundled code: {options.code_path}")
    count = 0
    for binary in binaries(options.code_path):
        flags, entitlements = verify(binary, options.configuration, options.adhoc)
        count += 1
        if not options.quiet:
            print(f"{binary}: {flags}; entitlements={json.dumps(entitlements, sort_keys=True)}")
    if count == 0:
        raise ValueError(f"No Mach-O code: {options.code_path}")
    if not options.quiet:
        print(f"Verified {count} Mach-O signatures and entitlement sets.")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit(error.stderr or str(error))
    except (OSError, ValueError, StopIteration) as error:
        sys.exit(str(error))
