#!/usr/bin/env python3
import hashlib
import io
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("build-deps.sh").read_text()


def function(name):
    match = re.search(rf"(?ms)^{name}\(\) \{{\n.*?^\}}", SCRIPT)
    if match is None:
        raise RuntimeError(f"Missing build function: {name}")
    return match.group()


class DependencyUnpackTests(unittest.TestCase):
    def setUp(self):
        workspace = tempfile.TemporaryDirectory(prefix="MacEase unpack tests ")
        self.addCleanup(workspace.cleanup)
        self.root = Path(workspace.name)
        for relative in ("Vendor/patches", "cache", "work", "out/licenses"):
            (self.root / relative).mkdir(parents=True)
        self.archive = self.root / "source.tar"
        with tarfile.open(self.archive, "w") as archive:
            for name, content in (("LICENSE", b"fixture license\n"), ("example.txt", b"upstream content\n")):
                entry = tarfile.TarInfo(f"fixture/{name}")
                entry.size = len(content)
                archive.addfile(entry, io.BytesIO(content))
        self.cache = self.root / "cache/fixture-source.tar"
        self.write_lock()
        self.driver = self.root / "build.sh"
        self.driver.write_text(
            'set -euo pipefail\nroot="$1"\nsrc="$root/cache"\nwork="$root/work"\n'
            'out="$root/out"\nlock="$root/Vendor/deps.lock"\n'
            + "\n\n".join(function(name) for name in ("lock_field", "fetch", "unpack", "keep_licenses", "build"))
            + '\nbuild_fixture() { printf "%s\\n" "$1" > "$root/built"; }\nbuild fixture\n'
        )

    def write_lock(self):
        checksum = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        (self.root / "Vendor/deps.lock").write_text(
            f"fixture 1 MIT {checksum} {self.archive.as_uri()} LICENSE\n"
        )

    def patch(self, original="upstream content"):
        (self.root / "Vendor/patches/fixture-required.patch").write_text(
            f"--- a/example.txt\n+++ b/example.txt\n@@ -1 +1 @@\n-{original}\n+patched content\n"
        )

    def build(self):
        return subprocess.run(
            ["bash", str(self.driver), str(self.root)], capture_output=True, text=True, timeout=10
        )

    def assert_failed(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / "built").exists())

    def test_unpatched_source_builds(self):
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.root / "built").is_file())
        self.assertEqual((self.root / "work/fixture/example.txt").read_text(), "upstream content\n")
        self.assertEqual((self.root / "out/licenses/fixture/LICENSE").read_text(), "fixture license\n")

    def test_patched_source_reuses_verified_cache(self):
        self.patch()
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / "work/fixture/example.txt").read_text(), "patched content\n")
        cached_stamp = self.cache.stat().st_mtime_ns
        self.archive.unlink()
        (self.root / "built").unlink()
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.root / "built").is_file())
        self.assertEqual((self.root / "work/fixture/example.txt").read_text(), "patched content\n")
        self.assertEqual(self.cache.stat().st_mtime_ns, cached_stamp)

    def test_required_patch_failure_stops_build(self):
        self.patch(original="outdated content")
        self.assert_failed(self.build())
        self.assertEqual((self.root / "work/fixture/example.txt").read_text(), "upstream content\n")

    def test_corrupt_archive_stops_after_partial_extraction(self):
        with tarfile.open(self.archive) as archive:
            header = archive.getmember("fixture/example.txt").offset
        contents = bytearray(self.archive.read_bytes())
        contents[header] ^= 1
        self.archive.write_bytes(contents)
        self.write_lock()
        self.assert_failed(self.build())
        self.assertEqual((self.root / "work/fixture/LICENSE").read_text(), "fixture license\n")

    def test_failed_download_does_not_promote_partial_file(self):
        partial = self.cache.with_suffix(".tar.part")
        partial.write_bytes(self.archive.read_bytes())
        self.archive.unlink()
        self.assert_failed(self.build())
        self.assertTrue(partial.is_file())
        self.assertFalse(self.cache.exists())


class DependencyBuildStampTests(unittest.TestCase):
    def setUp(self):
        workspace = tempfile.TemporaryDirectory(prefix="MacEase build stamp tests ")
        self.addCleanup(workspace.cleanup)
        self.root = Path(workspace.name)
        repository = Path(__file__).resolve().parent.parent
        for relative in (
            "scripts/generate-notices.sh", "scripts/build-hatchzip.sh", "Vendor/deps.lock",
            "Native/HatchZip/Cargo.toml", "Native/HatchZip/Cargo.lock", "Native/HatchZip/src/main.rs",
            "Vendor/licenses/swift-corelibs-foundation/LICENSE",
        ):
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(repository / relative, destination)
        for relative in ("Vendor/JSONCompare", "Vendor/patches"):
            shutil.copytree(repository / relative, self.root / relative)
        self.driver = self.root / "scripts/build-deps.sh"
        self.driver.write_text(SCRIPT[:SCRIPT.index("\njobs=")] + """
printf 'started\\n' >> "$root/attempts"
mkdir -p "$out/CNative.xcframework"
printf '#!/bin/sh\\n' > "$out/macease-hatchzip"
chmod +x "$out/macease-hatchzip"
printf 'partial notices\\n' > "$out/THIRD_PARTY_NOTICES.txt"
if [[ "${MACEASE_TEST_BUILD_FAIL:-0}" == 1 ]]; then exit 71; fi
printf 'complete notices\\n' > "$out/THIRD_PARTY_NOTICES.txt"
echo "$stamp" > "$stamp_file"
""")
        commands = self.root / "bin"
        commands.mkdir()
        for name in ("cmake", "meson", "ninja", "pkg-config", "make", "python3", "cargo"):
            command = commands / name
            command.write_text("#!/bin/sh\nexit 0\n")
            command.chmod(0o755)
        self.environment = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ["PATH"])
        self.notices = self.root / "Vendor/build/THIRD_PARTY_NOTICES.txt"

    def build(self, *, force=False, fail=False):
        return subprocess.run(
            ["bash", str(self.driver), *(["--force"] if force else [])],
            env=dict(self.environment, MACEASE_TEST_BUILD_FAIL="1" if fail else "0"),
            capture_output=True, text=True, timeout=10,
        )

    def test_unchanged_cache_skips_rebuild(self):
        for _ in range(2):
            result = self.build()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / "attempts").read_text().splitlines(), ["started"])
        self.assertEqual(self.notices.read_text(), "complete notices\n")

    def test_retry_rebuilds_after_partial_failure(self):
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.build(force=True, fail=True)
        self.assertEqual(result.returncode, 71, result.stdout + result.stderr)
        self.assertEqual(self.notices.read_text(), "partial notices\n")
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / "attempts").read_text().splitlines(), ["started"] * 3)
        self.assertEqual(self.notices.read_text(), "complete notices\n")


if __name__ == "__main__":
    unittest.main()
