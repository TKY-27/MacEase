#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
lock="$root/Vendor/media-tools.lock"
archives="$root/Vendor/src/media-tools"
work="$root/Vendor/build/media-tools-work"
prefix="$work/prefix"
runtime="$root/Vendor/build/media-tools"
stamp_file="$runtime/.stamp"
source_archive="$root/Vendor/build/media-tools-sources.tar.xz"
deployment_target="26.0"
python_version="3.14"
jobs=4
stamp="$(cat "$lock" "$0" "$root/docs/media-tools.md" "$root/Vendor/patches/lame-media-tools-export.patch" | shasum -a 256 | cut -d' ' -f1)"

if [[ "${1:-}" != --force && -f "$stamp_file" && -f "$source_archive" \
    && "$(cat "$stamp_file")" == "$stamp" && -x "$runtime/bin/python3" \
    && -x "$runtime/bin/node" && -x "$runtime/bin/ffmpeg" && -x "$runtime/bin/ffprobe" ]]; then
    echo "Media tools are up to date."
    exit 0
fi
[[ "$(uname -m)" == arm64 ]] || { echo "error: arm64 host required" >&2; exit 1; }
for tool in clang cmake make meson ninja pkg-config xcrun; do
    command -v "$tool" >/dev/null || { echo "error: missing $tool" >&2; exit 1; }
done
rm -rf "$runtime" "$prefix"
mkdir -p "$archives" "$work" "$runtime/bin" "$runtime/lib" "$runtime/licenses" "$prefix"
export MACOSX_DEPLOYMENT_TARGET="$deployment_target"
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
export CFLAGS="-O2 -arch arm64 -mmacosx-version-min=$deployment_target"
export LDFLAGS="-arch arm64 -mmacosx-version-min=$deployment_target"

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

run() {
    local name="$1"
    shift
    echo "Building $name"
    "$@" >"$work/$name.log" 2>&1 || { tail -60 "$work/$name.log" >&2; exit 1; }
}

unpack openssl
(
    cd "$work/openssl"
    run openssl-configure ./Configure darwin64-arm64-cc no-shared no-tests \
        --prefix="$prefix" --openssldir=/etc/ssl
    run openssl-build make -j"$jobs"
    run openssl-install make install_sw
)

unpack cpython
(
    cd "$work/cpython"
    cat > Modules/Setup.local <<'EOF'
*disabled*
_tkinter
_ctypes
readline
_curses
_curses_panel
_sqlite3
_lzma
_uuid
_zstd
EOF
    run python-configure env PKG_CONFIG=/usr/bin/false ./configure \
        --prefix="$runtime" --with-openssl="$prefix" --without-ensurepip \
        --disable-test-modules --with-readline=no --with-system-expat=no \
        --with-system-libmpdec=no
    run python-build make -j"$jobs"
    run python-install make install
)
ln -sf "python$python_version" "$runtime/bin/python3"
rm -rf "$runtime/include" "$runtime/share" "$runtime/lib/pkgconfig"
rm -rf "$runtime/lib/python$python_version/config-$python_version-darwin"
find "$runtime/lib/python$python_version" -name '*.opt-*.pyc' -delete
rm -f "$runtime/lib/libpython"*.a "$runtime/bin/"*config "$runtime/bin/idle"* "$runtime/bin/pydoc"*

unpack yt-dlp
unpack ejs
site_packages="$runtime/lib/python$python_version/site-packages"
mkdir -p "$site_packages"
cp -R "$work/yt-dlp/yt_dlp" "$site_packages/"
for package in gallery-dl requests urllib3 certifi idna charset-normalizer; do unpack "$package"; done
cp -R "$work/gallery-dl/gallery_dl" "$work/certifi/certifi" "$work/idna/idna" "$site_packages/"
cp -R "$work/requests/src/requests" "$work/urllib3/src/urllib3" \
    "$work/charset-normalizer/src/charset_normalizer" "$site_packages/"
"$runtime/bin/python3" -I -B -m zipfile -e "$(fetch ejs-wheel)" "$site_packages"
"$runtime/bin/python3" -I -B -c \
    'import yt_dlp_ejs.yt.solver as solver; print(solver.lib().split("*/", 1)[0] + "*/")' \
    > "$runtime/licenses/ejs/BUNDLED_DEPENDENCIES.txt"

unpack node
cp "$work/node/bin/node" "$runtime/bin/"

unpack lame
patch -d "$work/lame" -p1 < "$root/Vendor/patches/lame-media-tools-export.patch"
(
    cd "$work/lame"
    run lame-configure ./configure --prefix="$prefix" --disable-static --enable-shared \
        --disable-frontend --disable-dependency-tracking
    run lame-build make -j"$jobs"
    run lame-install make install
)

unpack libvpx
(
    cd "$work/libvpx"
    run vpx-configure ./configure --prefix="$prefix" --target=arm64-darwin25-gcc \
        --disable-examples --disable-tools --disable-docs --disable-unit-tests \
        --disable-shared --enable-static --enable-pic --disable-vp8
    run vpx-build make -j"$jobs"
    run vpx-install make install
)

unpack opus
run opus-configure cmake -S "$work/opus" -B "$work/opus/_build" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment_target" -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DBUILD_SHARED_LIBS=OFF -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF \
    -DOPUS_INSTALL_PKG_CONFIG_MODULE=ON -DCMAKE_POSITION_INDEPENDENT_CODE=ON
run opus-build cmake --build "$work/opus/_build" --parallel "$jobs"
run opus-install cmake --install "$work/opus/_build"

unpack dav1d
run dav1d-configure meson setup "$work/dav1d/_build" "$work/dav1d" \
    --buildtype release --default-library static --prefix "$prefix" --libdir lib \
    -Denable_tools=false -Denable_tests=false -Denable_examples=false \
    -Dc_args="$CFLAGS" -Dc_link_args="$LDFLAGS"
run dav1d-build ninja -C "$work/dav1d/_build" -j"$jobs" install

unpack ffmpeg
(
    cd "$work/ffmpeg"
    run ffmpeg-configure ./configure --prefix="$prefix" --arch=arm64 --target-os=darwin \
        --cc=clang --disable-gpl --disable-nonfree --disable-version3 \
        --disable-autodetect --disable-static --enable-shared --disable-doc --disable-debug \
        --disable-ffplay --enable-videotoolbox --enable-audiotoolbox --enable-securetransport --enable-zlib --enable-bzlib \
        --enable-libvpx --enable-libopus --enable-libmp3lame --enable-libdav1d \
        --extra-cflags="$CFLAGS -I$prefix/include" \
        --extra-ldflags="$LDFLAGS -L$prefix/lib" \
        --install-name-dir=@rpath
    cp ffbuild/config.mak "$runtime/ffmpeg-build-configuration.txt"
    run ffmpeg-build make -j"$jobs"
    run ffmpeg-install make install
)
cp "$prefix/bin/ffmpeg" "$prefix/bin/ffprobe" "$runtime/bin/"
cp -P "$prefix/lib/"*.dylib "$runtime/lib/"
while IFS= read -r -d '' executable; do
    if ! file -b "$executable" | grep -q 'Mach-O'; then continue; fi
    [[ "$(lipo -archs "$executable")" == arm64 ]] || {
        echo "error: non-arm64 code in $executable" >&2; exit 1;
    }
    while IFS= read -r dependency; do
        [[ "$dependency" == "$prefix/"* ]] || continue
        install_name_tool -change "$dependency" "@rpath/$(basename "$dependency")" "$executable"
    done < <(otool -L "$executable" | awk 'NR > 1 { print $1 }')
    case "$executable" in
        "$runtime/bin/ffmpeg"|"$runtime/bin/ffprobe")
            install_name_tool -add_rpath @executable_path/../lib "$executable" ;;
        *.dylib) install_name_tool -id "@rpath/$(basename "$executable")" "$executable" ;;
    esac
    codesign --force --sign - "$executable" >/dev/null 2>&1
    if otool -L "$executable" | grep -E '/opt/homebrew|/usr/local|media-tools-work' >/dev/null; then
        echo "error: external dependency in $executable" >&2; exit 1
    fi
done < <(find "$runtime/bin" "$runtime/lib" -type f \( -perm -111 -o -name '*.so' -o -name '*.dylib' \) -print0)

cp "$lock" "$runtime/manifest.lock"
cp "$root/docs/media-tools.md" "$runtime/BUILD.md"
{
    echo "MacEase download tools retain their upstream licenses."
    while read -r name version license _ url _; do
        [[ -z "$name" || "$name" == \#* ]] && continue
        printf '\n%s %s (%s)\n%s\n' "$name" "$version" "$license" "$url"
        if [[ -d "$runtime/licenses/$name" ]]; then
            for license_file in "$runtime/licenses/$name/"*; do cat "$license_file"; done
        fi
    done < "$lock"
} > "$runtime/THIRD_PARTY_NOTICES.txt"

env -i HOME="$work" PATH=/usr/bin:/bin "$runtime/bin/python3" -I -B -c \
    'import ssl,yt_dlp,yt_dlp_ejs.yt.solver; assert ssl.create_default_context().cert_store_stats()["x509_ca"] > 0; assert yt_dlp_ejs.yt.solver.core()'
env -i HOME="$work" PATH=/usr/bin:/bin "$runtime/bin/python3" -I -B -m yt_dlp --ignore-config --version
env -i HOME="$work" PATH=/usr/bin:/bin "$runtime/bin/node" --version
"$runtime/bin/python3" -I -B -c \
    'import yt_dlp_ejs.yt.solver as solver; print(solver.lib()); print("Object.assign(globalThis, lib);"); print(solver.core()); print("if (typeof jsc !== \"function\") process.exit(1)")' \
    | env -i HOME="$work" PATH=/usr/bin:/bin "$runtime/bin/node" --permission -
env -i HOME="$work" PATH=/usr/bin:/bin "$runtime/bin/ffmpeg" -version
[[ "$("$runtime/bin/node" --version)" == "v$(field node 2)" ]]
[[ "$("$runtime/bin/python3" -I -B -c 'import platform; print(platform.python_version())')" == "$(field cpython 2)" ]]
[[ "$("$runtime/bin/python3" -I -B -m yt_dlp --ignore-config --version)" == "$(field yt-dlp 2)" ]]
[[ "$("$runtime/bin/python3" -I -B -m gallery_dl --config-ignore --version)" == "$(field gallery-dl 2)" ]]
"$runtime/bin/ffprobe" -version >/dev/null
for protocol in https tls; do
    "$runtime/bin/ffmpeg" -hide_banner -protocols 2>/dev/null | grep -E "^[[:space:]]+$protocol$" >/dev/null
done
for encoder in h264_videotoolbox aac libvpx-vp9 libopus libmp3lame pcm_s24le flac; do
    "$runtime/bin/ffmpeg" -hide_banner -encoders 2>/dev/null | grep -E "[[:space:]]$encoder[[:space:]]" >/dev/null
done
"$runtime/bin/ffmpeg" -L > "$runtime/ffmpeg-license.txt" 2>&1
if grep -q 'GNU General Public License' "$runtime/ffmpeg-license.txt"; then
    echo "error: GPL FFmpeg build refused" >&2; exit 1
fi
source_bundle="$work/source-bundle"
rm -rf "$source_bundle"
mkdir -p "$source_bundle/sources" "$source_bundle/scripts" "$source_bundle/Vendor" "$source_bundle/docs" "$source_bundle/Vendor/patches"
while read -r name _; do
    [[ -z "$name" || "$name" == \#* || "$name" == node ]] && continue
    cp "$(fetch "$name")" "$source_bundle/sources/"
done < "$lock"
cp "$0" "$source_bundle/scripts/"
cp "$lock" "$source_bundle/Vendor/"
cp "$root/Vendor/patches/lame-media-tools-export.patch" "$source_bundle/Vendor/patches/"
cp "$root/docs/media-tools.md" "$source_bundle/docs/"
tar --options xz:compression-level=0,xz:threads=4 -cJf "$source_archive.part" -C "$source_bundle" .
mv "$source_archive.part" "$source_archive"

printf '%s\n' "$stamp" > "$stamp_file"
echo "Wrote $runtime and $source_archive"
