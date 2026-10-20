#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
lock="$root/Vendor/deps.lock"
licenses="$root/Vendor/build/licenses"
output="$root/Vendor/build/THIRD_PARTY_NOTICES.txt"

[[ -d "$licenses" ]] || { echo "error: run scripts/build-deps.sh first" >&2; exit 1; }

{
    echo "MacEase includes the following third-party software."
    echo
    while read -r name version license _ url files; do
        [[ -z "$name" || "$name" == \#* || "$files" == "-" && "$name" != "cfr" ]] && continue
        echo "================================================================================"
        echo "$name $version ($license)"
        echo "$url"
        echo "================================================================================"
        for file in "$licenses/$name"/*; do
            echo
            echo "--- $(basename "$file") ---"
            echo
            cat "$file"
        done
        echo
    done <"$lock"
} >"$output"

echo "Wrote $output"
