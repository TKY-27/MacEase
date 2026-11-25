field() { awk -v name="$1" -v column="$2" '$1 == name { print $column }' "$lock"; }

fetch() {
    local name="$1" url expected archive
    url="$(field "$name" 5)"
    expected="$(field "$name" 4)"
    archive="$archives/$name-$(basename "$url")"
    if [[ ! -f "$archive" ]]; then
        curl --fail --location --connect-timeout 20 --max-time 300 --retry 3 --output "$archive.part" "$url"
        mv "$archive.part" "$archive"
    fi
    [[ "$(shasum -a 256 "$archive" | cut -d' ' -f1)" == "$expected" ]] || {
        echo "error: SHA-256 mismatch for $name" >&2; exit 1;
    }
    echo "$archive"
}

unpack() {
    local name="$1" directory="$work/$1" archive license
    archive="$(fetch "$name")"
    rm -rf "$directory"
    mkdir -p "$directory" "$runtime/licenses/$name"
    tar xf "$archive" -C "$directory" --strip-components 1
    for license in $(field "$name" 6 | tr ',' ' '); do
        [[ "$license" == - ]] || cp "$directory/$license" "$runtime/licenses/$name/"
    done
}
