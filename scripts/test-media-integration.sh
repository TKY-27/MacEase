#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
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
if [ "$#" -ne 2 ]; then
    printf 'Usage: %s MEDIA_TOOLS_BIN FIXTURE_ROOT_URL\n' "$0" >&2
    exit 2
fi
"$package_root/.build/debug/MediaIntegration" "$1" "$2"
