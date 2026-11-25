import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

import yaml

workflow = yaml.safe_load(Path(sys.argv[1]).read_text())
steps = workflow["jobs"]["release"]["steps"]
script = next(step["run"] for step in steps if step.get("name") == "Create GitHub Release")
names = ["MacEase-3.1.0.dmg", "MacEase-3.1.0-media-tools-sources.tar.xz"]
assets = [name + suffix for name in names for suffix in ("", ".sha256")]
cases = ["success", "gh-failure"]
cases += [f"{kind}:{name}" for kind in ("missing", "empty") for name in assets]
cases += [f"{kind}:{name}" for kind in ("corrupt", "wrong-manifest", "garbage-manifest", "malformed-manifest") for name in names]

for case in cases:
    with tempfile.TemporaryDirectory(prefix="macease-release-test-") as directory:
        root = Path(directory)
        dist = root / "dist"
        dist.mkdir()
        for name in names:
            content = (name + " fixture\n").encode()
            (dist / name).write_bytes(content)
            digest = hashlib.sha256(content).hexdigest()
            (dist / (name + ".sha256")).write_text(f"{digest}  {name}\n")
        if ":" in case:
            kind, name = case.split(":", 1)
            path = dist / name
            if kind == "missing":
                path.unlink()
            elif kind == "empty":
                path.write_bytes(b"")
            elif kind == "corrupt":
                path.write_bytes(path.read_bytes() + b" changed")
            elif kind == "wrong-manifest":
                other = names[1 - names.index(name)]
                (dist / (name + ".sha256")).write_bytes((dist / (other + ".sha256")).read_bytes())
            elif kind == "garbage-manifest":
                manifest = dist / (name + ".sha256")
                manifest.write_text(manifest.read_text() + "garbage\n")
            elif kind == "malformed-manifest":
                (dist / (name + ".sha256")).write_text("invalid checksum\n")
        binary = root / "bin"
        binary.mkdir()
        stub = binary / "gh"
        stub.write_text("#!/bin/bash\nprintf '%s\\0' \"$@\" > \"$GH_CALL_RECORD\"\nexit \"${GH_STUB_EXIT:-0}\"\n")
        stub.chmod(0o755)
        record = root / "gh-call"
        environment = dict(os.environ, PATH=str(binary) + ":" + os.environ["PATH"],
                           MACEASE_VERSION="3.1.0", GITHUB_REF_NAME="v3.1.0", RUNNER_TEMP=directory,
                           GH_CALL_RECORD=str(record), GH_STUB_EXIT="47" if case == "gh-failure" else "0")
        (root / "release-notes.md").write_text("Fixture release notes\n")
        result = subprocess.run(["bash", "-e", "-c", script], cwd=root, env=environment,
                                capture_output=True, text=True, timeout=15)
        invoked = record.exists()
        if case in ("success", "gh-failure"):
            arguments = record.read_bytes().decode().split("\0")[:-1]
            expected = ["release", "create", "v3.1.0", *["dist/" + name for name in assets],
                        "--verify-tag", "--title", "MacEase 3.1.0", "--notes-file", str(root / "release-notes.md")]
            assert arguments == expected, (case, arguments)
            assert result.returncode == (47 if case == "gh-failure" else 0), (case, result.stderr)
        else:
            assert result.returncode != 0 and not invoked, (case, result.returncode, invoked, result.stdout, result.stderr)
        print(json.dumps({"case": case, "exit": result.returncode, "gh_invoked": invoked, "result": "passed"}))
print(f"Passed {len(cases)} publication fixtures; no GitHub Release was created.")
