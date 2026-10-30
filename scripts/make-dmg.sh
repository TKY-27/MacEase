#!/usr/bin/env bash
# MACEASE_ALLOW_ADHOC=1 is only for local testing.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
identity="MacEase Release"
app_name="MacEase"
archive="$root/build/$app_name.xcarchive"
staging="$root/build/dmg"
dist="$root/dist"

sign_args=(--force --timestamp=none)
if [[ -n "${MACEASE_SIGNING_KEYCHAIN:-}" ]]; then
    if ! security find-certificate -c "$identity" "$MACEASE_SIGNING_KEYCHAIN" >/dev/null; then
        echo "error: no \"$identity\" certificate in $MACEASE_SIGNING_KEYCHAIN" >&2
        exit 1
    fi
    sign_args+=(--sign "$identity" --keychain "$MACEASE_SIGNING_KEYCHAIN")
elif [[ "${MACEASE_ALLOW_ADHOC:-}" == 1 ]]; then
    echo "warning: signing ad hoc; this DMG is for local testing only" >&2
    sign_args+=(--sign -)
else
    echo "error: no signing identity configured." >&2
    echo "Set MACEASE_SIGNING_KEYCHAIN to an unlocked keychain file holding \"$identity\"" >&2
    echo "(see scripts/create-signing-identity.sh), or MACEASE_ALLOW_ADHOC=1 for a local test build." >&2
    exit 1
fi

cd "$root"
scripts/generate-notices.sh
xcodegen generate
rm -rf "$archive"
xcodebuild -project "$app_name.xcodeproj" -scheme "$app_name" -destination 'generic/platform=macOS' \
    -derivedDataPath build/DerivedData -archivePath "$archive" -quiet archive

app="$archive/Products/Applications/$app_name.app"
appex="$app/Contents/PlugIns/MacEaseFinderSync.appex"

# Preserve Xcode's expanded entitlements.
codesign "${sign_args[@]}" "$app/Contents/Resources/macease-hatchzip"
codesign "${sign_args[@]}" --preserve-metadata=entitlements "$appex"
codesign "${sign_args[@]}" --preserve-metadata=entitlements "$app"

appex_entitlements="$(codesign -d --entitlements - --xml "$appex" 2>/dev/null)"
if [[ "$appex_entitlements" != *com.apple.security.app-sandbox* ]]; then
    echo "error: the Finder Sync extension lost its sandbox entitlement" >&2
    exit 1
fi
codesign --verify --deep --strict --verbose=2 "$app"
spctl --assess --type execute --verbose=4 "$app" \
    || echo "note: Gatekeeper rejects unnotarized builds until Open Anyway" >&2

version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
dmg_name="$app_name-$version.dmg"
rm -rf "$staging"
mkdir -p "$staging" "$dist"
ditto "$app" "$staging/$app_name.app"
ln -s /Applications "$staging/Applications"
# LZMA: about 26% smaller than UDZO.
hdiutil create -volname "$app_name" -srcfolder "$staging" -format ULMO -ov "$dist/$dmg_name"
(cd "$dist" && shasum -a 256 "$dmg_name" >"$dmg_name.sha256")
echo "Wrote $dist/$dmg_name"
