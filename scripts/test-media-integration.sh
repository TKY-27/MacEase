#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "${1:-}" != "--build-only" ] && { [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; }; then
    printf 'Usage: %s MEDIA_TOOLS_BIN FIXTURE_ROOT_URL FIXTURE_DIR [--capacity]\n' "$0" >&2
    exit 2
fi
if [ "$#" -eq 4 ] && [ "$4" != "--capacity" ]; then
    printf 'Unknown integration mode: %s\n' "$4" >&2
    exit 2
fi
package_root="$repo_root/build/media-integration"
mkdir -p "$package_root/Sources/MediaIntegration"
cp "$repo_root/Tests/MediaIntegration/main.swift" "$package_root/Sources/MediaIntegration/main.swift"
cat > "$package_root/Package.swift" <<EOF
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MediaIntegration",
    platforms: [.macOS("26.0")],
    dependencies: [.package(path: "$repo_root/Packages/MacEaseKit")],
    targets: [
        .executableTarget(name: "MediaIntegration", dependencies: [
            .product(name: "Engine", package: "MacEaseKit")
        ])
    ]
)
EOF
if ! swift build --disable-sandbox --jobs 4 --cache-path "$repo_root/Packages/MacEaseKit/.build" \
    --package-path "$package_root" --product MediaIntegration > "$package_root/build.log" 2>&1; then
    rg 'error:|warning:' "$package_root/build.log" | tail -30
    exit 1
fi
if [ "${1:-}" = "--build-only" ]; then
    printf 'Built %s\n' "$package_root/.build/debug/MediaIntegration"
    exit 0
fi
if [ "${4:-}" = "--capacity" ]; then
    image="$package_root/capacity.sparseimage"
    mount_dir="$package_root/capacity-mount"
    if [ -e "$image" ] || [ -e "$mount_dir" ]; then
        printf 'Capacity fixture path already exists; refusing to replace it\n' >&2
        exit 1
    fi
    /usr/bin/hdiutil create -quiet -size 32m -fs HFS+ -type SPARSE -volname MacEaseCapacityFixture "$image"
    mkdir "$mount_dir"
    if ! /usr/bin/hdiutil attach -quiet -nobrowse -mountpoint "$mount_dir" "$image"; then
        rmdir "$mount_dir"
        rm "$image"
        exit 1
    fi
    cleanup_capacity() {
        if /usr/bin/hdiutil detach -quiet "$mount_dir"; then
            rmdir "$mount_dir"
            rm "$image"
        else
            printf 'Capacity volume remains mounted at %s\n' "$mount_dir" >&2
            exit 1
        fi
    }
    trap cleanup_capacity EXIT
    touch "$mount_dir/.macease-capacity-fixture"
    mkdir "$mount_dir/output"
    python3 - "$mount_dir" "$3/source.mp4" <<'PY'
import errno
import os
import sys

mount, source = sys.argv[1:]
source_size = os.path.getsize(source)
fill = os.path.join(mount, "capacity-fill")
with open(fill, "wb", buffering=0) as output:
    while True:
        available = os.statvfs(mount).f_bavail * os.statvfs(mount).f_frsize
        if available < source_size:
            break
        amount = min(65536, max(4096, available - source_size // 4))
        try:
            output.write(bytes(amount))
        except OSError as error:
            if error.errno != errno.ENOSPC:
                raise
            break
if os.statvfs(mount).f_bavail * os.statvfs(mount).f_frsize >= source_size:
    raise RuntimeError("Capacity fixture still has room for the source file")
PY
    "$package_root/.build/debug/MediaIntegration" "$1" "$2" "$3" "$mount_dir"
    exit 0
fi
"$package_root/.build/debug/MediaIntegration" "$1" "$2" "$3"
