#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fixture_root=$(mktemp -d)
trap 'rm -rf "$fixture_root"' EXIT
mkdir -p "$fixture_root/Sources/FeedbackFixture"
cp "$repo_root/App/Sources/SettingsStore.swift" "$fixture_root/Sources/FeedbackFixture/"
cp "$repo_root/App/Sources/UpdateChecker.swift" "$fixture_root/Sources/FeedbackFixture/"
cp "$repo_root/App/Sources/HostConfiguration.swift" "$fixture_root/Sources/FeedbackFixture/"
cp "$repo_root/Tests/FeedbackFixture/main.swift" "$fixture_root/Sources/FeedbackFixture/"
cat > "$fixture_root/Package.swift" <<EOF
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FeedbackFixture",
    platforms: [.macOS("26.0")],
    dependencies: [.package(path: "$repo_root/Packages/MacEaseKit")],
    targets: [
        .executableTarget(name: "FeedbackFixture", dependencies: [
            .product(name: "Engine", package: "MacEaseKit"),
            .product(name: "MenuCatalog", package: "MacEaseKit")
        ])
    ]
)
EOF
if ! swift build --disable-sandbox --cache-path "$repo_root/Packages/MacEaseKit/.build" \
    --package-path "$fixture_root" --product FeedbackFixture > "$fixture_root/build.log" 2>&1; then
    rg 'error:|warning:' "$fixture_root/build.log" | tail -30
    exit 1
fi
app_root="$fixture_root/FeedbackFixture.app/Contents"
mkdir -p "$app_root/MacOS" "$app_root/Resources"
cp "$fixture_root/.build/debug/FeedbackFixture" "$app_root/MacOS/"
cp -R "$fixture_root/.build/debug/MacEaseKit_Engine.bundle" "$app_root/Resources/"
cat > "$app_root/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.tky27.MacEase.FeedbackFixture</string>
<key>CFBundleShortVersionString</key><string>2.1.0</string>
<key>MacEaseURLScheme</key><string>macease-fixture</string>
<key>MacEaseSupportFolder</key><string>MacEaseFeedbackFixture</string>
</dict></plist>
EOF
"$app_root/MacOS/FeedbackFixture"
