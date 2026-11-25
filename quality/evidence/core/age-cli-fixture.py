import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import time


for binary in sys.argv[1:]:
    with tempfile.TemporaryDirectory(prefix="macease-age-fifo-") as directory:
        source = Path(directory) / "input"
        output = Path(directory) / "output.age"
        os.mkfifo(source, 0o600)
        password = b"correct horse battery staple"
        started = time.monotonic()
        process = subprocess.Popen(
            [str(Path(binary).resolve()), "encrypt", str(source), str(output)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            stdout, stderr = process.communicate(
                struct.pack(">I", len(password)) + password, timeout=2
            )
            outcome = "rejected" if process.returncode != 0 else "accepted"
        except subprocess.TimeoutExpired:
            process.kill()
            stdout, stderr = process.communicate()
            outcome = "blocked"
        print(json.dumps({
            "binary": Path(binary).name,
            "result": outcome,
            "code": process.returncode,
            "seconds": time.monotonic() - started,
            "stdout": stdout.decode(),
            "stderr": stderr.decode(),
            "output_exists": output.exists(),
        }))
