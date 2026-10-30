#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
command -v cargo >/dev/null || { echo "error: cargo is missing; run make bootstrap" >&2; exit 1; }
read -r _ revision _ checksum url _ < <(awk '$1 == "hatchzip-core" { print }' "$root/Vendor/deps.lock")
archive="$root/Vendor/src/hatchzip-$revision.tar.gz"
source="$root/Vendor/src/hatchzip"
mkdir -p "$root/Vendor/src" "$root/Vendor/build/licenses/hatchzip-core"
if [[ ! -f "$archive" ]]; then
    curl -fsSL --retry 3 "$url" -o "$archive.pending"
    mv "$archive.pending" "$archive"
fi
[[ "$(shasum -a 256 "$archive" | cut -d' ' -f1)" == "$checksum" ]] || {
    echo "error: HatchZip source checksum mismatch" >&2
    exit 1
}
rm -rf "$source"
mkdir -p "$source"
tar -xf "$archive" -C "$source" --strip-components 1
patch -d "$source" -p1 < "$root/Vendor/patches/hatchzip-core-macease.patch"
export MACOSX_DEPLOYMENT_TARGET=26.0
export CARGO_TARGET_DIR="$root/Vendor/build/hatchzip-target"
cargo build --release --locked --manifest-path "$root/Native/HatchZip/Cargo.toml"
cp "$CARGO_TARGET_DIR/release/macease-hatchzip" "$root/Vendor/build/macease-hatchzip"
cp "$source/LICENSE-MIT" "$source/LICENSE-APACHE" "$root/Vendor/build/licenses/hatchzip-core/"
cargo metadata --locked --filter-platform aarch64-apple-darwin \
    --manifest-path "$root/Native/HatchZip/Cargo.toml" --format-version 1 \
    > "$CARGO_TARGET_DIR/metadata.json"
python3 - "$CARGO_TARGET_DIR/metadata.json" "$root/Vendor/build/hatchzip-third-party.txt" <<'PY'
import json
from pathlib import Path
import sys
metadata = json.loads(Path(sys.argv[1]).read_text())
resolved = {node['id'] for node in metadata['resolve']['nodes']}
with Path(sys.argv[2]).open('w') as output:
    for package in sorted(metadata['packages'], key=lambda package: package['name']):
        if package['id'] not in resolved or package['name'] in {'hatchzip-core', 'macease-hatchzip'}:
            continue
        directory = Path(package['manifest_path']).parent
        licenses = sorted({path for pattern in ['LICENSE*', 'COPYING*', 'NOTICE*']
                           for path in directory.glob(pattern) if path.is_file()})
        if not licenses:
            raise RuntimeError(f"Missing license text for {package['name']}")
        output.write(f"\n{package['name']} {package['version']} ({package['license']})\n")
        output.write(f"{package.get('repository') or package.get('homepage') or package['source']}\n")
        for license_path in licenses:
            output.write(f"\n--- {license_path.name} ---\n")
            output.write(license_path.read_text())
PY
