import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

repository = Path(sys.argv[1]).resolve()
go = Path(sys.argv[2]).resolve()
with tempfile.TemporaryDirectory(prefix="macease-test-gate-") as directory:
    root = Path(directory)
    shutil.copyfile(repository / "Makefile", root / "Makefile")
    shutil.copytree(repository / "Vendor/AgeBridge", root / "Vendor/AgeBridge")
    if (repository / "scripts/test-build-deps.py").exists():
        (root / "scripts").mkdir()
        for name in ("test-build-deps.py", "build-deps.sh"):
            shutil.copyfile(repository / "scripts" / name, root / "scripts" / name)
        for relative in ("scripts/generate-notices.sh", "scripts/build-hatchzip.sh", "Vendor/deps.lock",
                         "Native/HatchZip/Cargo.toml", "Native/HatchZip/Cargo.lock", "Native/HatchZip/src/main.rs",
                         "Vendor/licenses/swift-corelibs-foundation/LICENSE"):
            destination = root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(repository / relative, destination)
        for relative in ("Vendor/JSONCompare", "Vendor/patches"):
            shutil.copytree(repository / relative, root / relative)
    binaries = root / "bin"
    binaries.mkdir()
    media = root / "media"
    media.mkdir()
    record = root / "steps"
    for path, script in [
        (media / "python3", 'printf "js\\n" >> "$STEP_RECORD"\n'),
        (binaries / "swift", 'printf "swift\\n" >> "$STEP_RECORD"\n'),
        (binaries / "go", 'printf "go\\n" >> "$STEP_RECORD"\nexec "$ACTUAL_GO" "$@"\n'),
    ]:
        path.write_text("#!/bin/sh\nset -eu\n" + script)
        path.chmod(0o755)
    environment = dict(os.environ, PATH=str(binaries) + ":" + os.environ["PATH"],
                       STEP_RECORD=str(record), ACTUAL_GO=str(go),
                       GOFLAGS="-run=TestPassphraseFrameIsBounded")
    command = ["make", "test", "MEDIA_TOOLS=" + str(media)]
    success = subprocess.run(command, cwd=root, env=environment, capture_output=True, text=True, timeout=60)
    assert success.returncode == 0, success.stdout + success.stderr
    assert record.read_text().splitlines() == ["js", "go", "swift"], record.read_text()
    print("make test success: actual Go test runs between JS and Swift fixture commands")

    record.unlink()
    (root / "Vendor/AgeBridge/gate_failure_test.go").write_text(
        'package main\nimport "testing"\nfunc TestMakeGateFailure(t *testing.T) { t.Fatal("fixture failure") }\n'
    )
    environment["GOFLAGS"] = "-run=TestMakeGateFailure"
    failure = subprocess.run(command, cwd=root, env=environment, capture_output=True, text=True, timeout=60)
    assert failure.returncode != 0, failure.stdout + failure.stderr
    assert record.read_text().splitlines() == ["js", "go"], record.read_text()
    assert "fixture failure" in failure.stdout + failure.stderr
    print("make test failure: actual failing Go test propagates and Swift fixture never runs")

dry = subprocess.run(["make", "-n", "test-device"], cwd=repository, capture_output=True, text=True, timeout=10)
assert dry.returncode == 0, dry.stdout + dry.stderr
assert dry.stdout.count("go test -mod=readonly -count=1 ./...") == 1
assert dry.stdout.index("go test -mod=readonly -count=1 ./...") < dry.stdout.index("MACEASE_DEVICE_TESTS=1")
assert dry.stdout.index("MACEASE_DEVICE_TESTS=1") < dry.stdout.rindex("make test-app")
print("make test-device dry run: Go suite precedes Swift device suite; app test dispatch retained")
print("No macOS app build, package suite, or device test was executed by these fixtures.")
