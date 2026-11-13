#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
python="${MACEASE_UPSCALER_BUILD_PYTHON:-python3.11}"
if "$python" -I -B "$root/scripts/build-upscaler.py" --verify-only; then exit 0; fi
work="$root/Vendor/build/upscaler-work"
mkdir -p "$work"
if [[ ! -x "$work/venv/bin/python" ]]; then "$python" -m venv "$work/venv"; fi
awk '/==/ { print }' "$root/Vendor/upscaler.lock" > "$work/requirements.txt"
"$work/venv/bin/python" -m pip install --requirement "$work/requirements.txt"
"$work/venv/bin/python" -I -B "$root/scripts/build-upscaler.py"
