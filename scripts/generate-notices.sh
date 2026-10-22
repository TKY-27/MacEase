#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
lock="$root/Vendor/deps.lock"
licenses="$root/Vendor/build/licenses"
output="${1:-$root/Vendor/build/THIRD_PARTY_NOTICES.txt}"
resolved="$root/Packages/MacEaseKit/Package.resolved"
package_licenses="$root/Vendor/licenses"

# Carrier pins prevent stale bundled notices.
swift_packages=(
    "swift-cmark 0.9.0 BSD-2-Clause swift-cmark 0.9.0 https://github.com/swiftlang/swift-cmark"
    "yams 6.2.2 MIT yams 6.2.2 https://github.com/jpsim/Yams"
    "libyaml acd6f6f014c25e46363e718381e0b35205df2d83 MIT yams 6.2.2 https://github.com/yaml/libyaml"
)

toml_header="$root/Packages/MacEaseKit/Sources/TOMLBridge/toml.hpp"
toml_pin="$(awk '$1 == "tomlplusplus" { print }' "$lock")"
read -r toml_name toml_version toml_license toml_hash toml_url _ <<<"$toml_pin"
[[ "$toml_name" == "tomlplusplus" && -f "$toml_header" ]] || {
    echo "error: vendored toml++ source or pin is missing" >&2
    exit 1
}
[[ "$(shasum -a 256 "$toml_header" | cut -d' ' -f1)" == "$toml_hash" ]] || {
    echo "error: vendored toml++ SHA-256 mismatch" >&2
    exit 1
}

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
    notice "$toml_name" "$toml_version" "$toml_license" "$toml_url" "$package_licenses/$toml_name"
    for entry in "${swift_packages[@]}"; do
        read -r name version license _ _ url <<<"$entry"
        notice "$name" "$version" "$license" "$url" "$package_licenses/$name"
    done
} >"$output"

echo "Wrote $output"
