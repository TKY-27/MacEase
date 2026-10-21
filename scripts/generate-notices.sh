#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
lock="$root/Vendor/deps.lock"
licenses="$root/Vendor/build/licenses"
output="$root/Vendor/build/THIRD_PARTY_NOTICES.txt"
resolved="$root/Packages/MacEaseKit/Package.resolved"
package_licenses="$root/Vendor/licenses"

# Fields: name version license carrier-pin pin-version url
swift_packages=(
    "swift-cmark 0.9.0 BSD-2-Clause swift-cmark 0.9.0 https://github.com/swiftlang/swift-cmark"
    "yams 6.2.2 MIT yams 6.2.2 https://github.com/jpsim/Yams"
    "libyaml acd6f6f014c25e46363e718381e0b35205df2d83 MIT yams 6.2.2 https://github.com/yaml/libyaml"
    "tomlkit 0.6.0 MIT tomlkit 0.6.0 https://github.com/LebJe/TOMLKit"
    "tomlplusplus 3.4.0 MIT tomlkit 0.6.0 https://github.com/marzer/tomlplusplus"
)

[[ -d "$licenses" ]] || { echo "error: run scripts/build-deps.sh first" >&2; exit 1; }

pinned_version() {
    local index=0 identity
    while identity="$(plutil -extract "pins.$index.identity" raw -o - "$resolved" 2>/dev/null)"; do
        if [[ "$identity" == "$1" ]]; then
            plutil -extract "pins.$index.state.version" raw -o - "$resolved"
            return
        fi
        index=$((index + 1))
    done
    echo "error: $1 is not pinned in $resolved" >&2
    exit 1
}

for entry in "${swift_packages[@]}"; do
    read -r name _ _ pin pin_version _ <<<"$entry"
    actual="$(pinned_version "$pin")"
    [[ "$actual" == "$pin_version" ]] || {
        echo "error: $pin is $actual in Package.resolved but notices expect $pin_version for $name" >&2
        exit 1
    }
done

notice() {
    local name="$1" version="$2" license="$3" url="$4" directory="$5" file
    echo "================================================================================"
    echo "$name $version ($license)"
    echo "$url"
    echo "================================================================================"
    for file in "$directory"/*; do
        echo
        echo "--- $(basename "$file") ---"
        echo
        cat "$file"
    done
    echo
}

{
    echo "MacEase includes the following third-party software."
    echo
    while read -r name version license _ url files; do
        [[ -z "$name" || "$name" == \#* || "$files" == "-" && "$name" != "cfr" ]] && continue
        notice "$name" "$version" "$license" "$url" "$licenses/$name"
    done <"$lock"
    for entry in "${swift_packages[@]}"; do
        read -r name version license _ _ url <<<"$entry"
        notice "$name" "$version" "$license" "$url" "$package_licenses/$name"
    done
} >"$output"

echo "Wrote $output"
