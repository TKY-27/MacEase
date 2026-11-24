#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
code_path="${1%/}"
shift
[[ -e "$code_path" ]] || { echo "error: missing bundled code: $code_path" >&2; exit 1; }
if [[ $# -eq 2 && "$1" == --sign && "$2" == - ]] \
    && python3 "$root/scripts/verify-signing.py" "$code_path" --adhoc --quiet >/dev/null 2>&1; then
    echo "Bundled code signatures are up to date: $code_path"
    exit 0
fi

find "$code_path" -type f -print0 | while IFS= read -r -d '' binary; do
    if ! file -b "$binary" | grep -q '^Mach-O'; then continue; fi
    sign_options=(--force --options runtime --timestamp=none "$@")
    case "$binary" in
        */media-tools/bin/python3.*|*/media-tools/bin/ffmpeg|*/media-tools/bin/ffprobe|\
        */ai-audio/bin/sherpa-onnx-offline-denoiser|*/ai-audio/bin/sherpa-onnx-offline-source-separation)
            sign_options+=(--entitlements "$root/scripts/entitlements/library-validation.plist") ;;
    esac
    codesign "${sign_options[@]}" "$binary"
done
python3 "$root/scripts/verify-signing.py" "$code_path"
