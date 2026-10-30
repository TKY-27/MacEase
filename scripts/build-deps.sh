#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
lock="$root/Vendor/deps.lock"
src="$root/Vendor/src"
out="$root/Vendor/build"
work="$out/work"
prefix="$out/prefix"
deployment_target="26.0"
stamp_file="$out/.stamp"

stamp_inputs=("$lock" "$0" "$root/scripts/generate-notices.sh" "$root/scripts/build-hatchzip.sh")
stamp_inputs+=("$root/Native/HatchZip/Cargo.toml" "$root/Native/HatchZip/Cargo.lock" "$root/Native/HatchZip/src/main.rs")
stamp_inputs+=("$root"/Vendor/JSONCompare/*.mm "$root"/Vendor/JSONCompare/*.hpp)
stamp_inputs+=("$root"/Vendor/JSONCompare/*.py "$root"/Vendor/JSONCompare/include/*.h)
stamp_inputs+=("$root/Vendor/JSONCompare/NOTICE" "$root/Vendor/licenses/swift-corelibs-foundation/LICENSE")
if [[ -d "$root/Vendor/patches" ]]; then
    stamp_inputs+=("$root"/Vendor/patches/*.patch)
fi
stamp="$(cat "${stamp_inputs[@]}" | shasum -a 256 | cut -d' ' -f1)"
if [[ "${1:-}" != "--force" && -f "$stamp_file" && "$(cat "$stamp_file")" == "$stamp" \
    && -d "$out/CNative.xcframework" && -f "$out/THIRD_PARTY_NOTICES.txt" && -x "$out/macease-hatchzip" ]]; then
    echo "Native dependencies are up to date."
    exit 0
fi

for tool in cmake meson ninja pkg-config make python3 cargo; do
    command -v "$tool" >/dev/null || { echo "error: $tool is missing; run make bootstrap" >&2; exit 1; }
done

rm -rf "$work" "$prefix" "$out/CNative.xcframework" "$out/licenses" "$out/cfr.jar" "$out/THIRD_PARTY_NOTICES.txt"
mkdir -p "$src" "$work" "$prefix" "$out/licenses"

jobs="$(sysctl -n hw.ncpu)"
export MACOSX_DEPLOYMENT_TARGET="$deployment_target"
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
arch_flags="-arch arm64 -mmacosx-version-min=$deployment_target"

lock_field() {
    awk -v name="$1" -v col="$2" '$1 == name { print $col }' "$lock"
}

fetch() {
    local name="$1" url sha file
    url="$(lock_field "$name" 5)"
    sha="$(lock_field "$name" 4)"
    file="$src/$name-$(basename "$url")"
    if [[ ! -f "$file" ]] || [[ "$(shasum -a 256 "$file" | cut -d' ' -f1)" != "$sha" ]]; then
        echo "Downloading $name" >&2
        curl -sSLf --retry 3 -o "$file.part" "$url"
        mv "$file.part" "$file"
    fi
    if [[ "$(shasum -a 256 "$file" | cut -d' ' -f1)" != "$sha" ]]; then
        echo "error: SHA-256 mismatch for $name" >&2
        exit 1
    fi
    echo "$file"
}

unpack() {
    local name="$1" archive dir
    archive="$(fetch "$name")"
    dir="$work/$name"
    mkdir -p "$dir"
    tar xf "$archive" -C "$dir" --strip-components 1
    for patch in "$root/Vendor/patches/$name"-*.patch; do
        [[ -f "$patch" ]] && patch -d "$dir" -p1 < "$patch" >&2
    done
    echo "$dir"
}

keep_licenses() {
    local name="$1" dir="$2" file
    mkdir -p "$out/licenses/$name"
    for file in $(lock_field "$name" 6 | tr ',' ' '); do
        cp "$dir/$file" "$out/licenses/$name/"
    done
}

cmake_build() {
    local dir="$1"
    shift
    cmake -S "$dir" -B "$dir/_build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment_target" \
        -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DCMAKE_PREFIX_PATH="$prefix" \
        -DCMAKE_FIND_ROOT_PATH="$prefix" \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TESTING=OFF \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -Wno-dev "$@" >"$dir/_configure.log" 2>&1 || { tail -40 "$dir/_configure.log" >&2; exit 1; }
    cmake --build "$dir/_build" --parallel "$jobs" >"$dir/_build.log" 2>&1 || { tail -40 "$dir/_build.log" >&2; exit 1; }
    cmake --install "$dir/_build" >/dev/null
}

build() {
    local name="$1" dir
    echo "Building $name"
    dir="$(unpack "$name")"
    keep_licenses "$name" "$dir"
    "build_$name" "$dir"
}

build_libdeflate() {
    cmake_build "$1" -DLIBDEFLATE_BUILD_SHARED_LIB=OFF -DLIBDEFLATE_BUILD_GZIP=OFF
}

build_xz() {
    cmake_build "$1" -DXZ_NLS=OFF -DXZ_DOC=OFF -DXZ_TOOL_XZ=OFF -DXZ_TOOL_XZDEC=OFF \
        -DXZ_TOOL_LZMADEC=OFF -DXZ_TOOL_LZMAINFO=OFF -DXZ_TOOL_SCRIPTS=OFF -DXZ_TOOL_SYMLINKS=OFF
}

build_zstd() {
    cmake -S "$1/build/cmake" -B "$1/_build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment_target" \
        -DCMAKE_INSTALL_PREFIX="$prefix" -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_SHARED=OFF \
        -DZSTD_BUILD_STATIC=ON -DZSTD_BUILD_TESTS=OFF -DZSTD_LEGACY_SUPPORT=OFF >"$1/_configure.log" 2>&1 \
        || { tail -40 "$1/_configure.log" >&2; exit 1; }
    cmake --build "$1/_build" --parallel "$jobs" >"$1/_build.log" 2>&1 || { tail -40 "$1/_build.log" >&2; exit 1; }
    cmake --install "$1/_build" >/dev/null
}

build_libogg() {
    cmake_build "$1" -DINSTALL_DOCS=OFF
}

build_libvorbis() {
    cmake_build "$1"
}

build_opus() {
    cmake_build "$1" -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF -DOPUS_INSTALL_PKG_CONFIG_MODULE=ON
}

# The FLAC command line tools are GPL.
build_flac() {
    cmake_build "$1" -DBUILD_PROGRAMS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_DOCS=OFF -DBUILD_CXXLIBS=OFF \
        -DINSTALL_MANPAGES=OFF -DWITH_OGG=OFF -DINSTALL_CMAKE_CONFIG_MODULE=OFF
}

build_libwebp() {
    cmake_build "$1" -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
        -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
        -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF \
        -DWEBP_BUILD_LIBWEBPMUX=ON
}

build_libaom() {
    cmake_build "$1" -DENABLE_DOCS=0 -DENABLE_EXAMPLES=0 -DENABLE_TESTDATA=0 -DENABLE_TESTS=0 \
        -DENABLE_TOOLS=0 -DCONFIG_AV1_DECODER=0
}

build_dav1d() {
    meson setup "$1/_build" "$1" --buildtype release --default-library static --prefix "$prefix" \
        --libdir lib -Denable_tools=false -Denable_tests=false -Denable_examples=false \
        -Dc_args="$arch_flags" -Dc_link_args="$arch_flags" >"$1/_configure.log" 2>&1 \
        || { tail -40 "$1/_configure.log" >&2; exit 1; }
    ninja -C "$1/_build" install >"$1/_build.log" 2>&1 || { tail -40 "$1/_build.log" >&2; exit 1; }
}

build_libavif() {
    cmake_build "$1" -DAVIF_CODEC_AOM=SYSTEM -DAVIF_CODEC_AOM_DECODE=OFF -DAVIF_CODEC_AOM_ENCODE=ON \
        -DAVIF_CODEC_DAV1D=SYSTEM -DAVIF_LIBYUV=OFF -DAVIF_LIBSHARPYUV=OFF -DAVIF_BUILD_APPS=OFF \
        -DAVIF_BUILD_TESTS=OFF -DAVIF_JPEG=OFF -DAVIF_ZLIBPNG=OFF -DAVIF_LIBXML2=OFF
}

build_libjxl() {
    local dir="$1" dep
    for dep in highway brotli skcms; do
        rm -rf "${dir:?}/third_party/$dep"
        mkdir -p "$dir/third_party/$dep"
        tar xf "$(fetch "$dep")" -C "$dir/third_party/$dep" --strip-components 1
        keep_licenses "$dep" "$dir/third_party/$dep"
    done
    cmake_build "$dir" -DJPEGXL_ENABLE_TOOLS=OFF -DJPEGXL_ENABLE_DOXYGEN=OFF \
        -DJPEGXL_ENABLE_MANPAGES=OFF -DJPEGXL_ENABLE_BENCHMARK=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF \
        -DJPEGXL_ENABLE_JNI=OFF -DJPEGXL_ENABLE_SJPEG=OFF -DJPEGXL_ENABLE_OPENEXR=OFF \
        -DJPEGXL_ENABLE_JPEGLI=OFF -DJPEGXL_ENABLE_PLUGINS=OFF -DJPEGXL_ENABLE_SKCMS=ON \
        -DJPEGXL_BUNDLE_LIBPNG=OFF -DJPEGXL_ENABLE_TRANSCODE_JPEG=OFF -DJPEGXL_ENABLE_AVX512=OFF \
        -DJPEGXL_FORCE_SYSTEM_BROTLI=OFF -DJPEGXL_FORCE_SYSTEM_HWY=OFF -DJPEGXL_ENABLE_HWY_SVE=OFF
    find "$dir/_build/third_party" -name '*.a' -exec cp {} "$prefix/lib/" \;
}

build_libvpx() {
    (
        cd "$1"
        ./configure --target=arm64-darwin25-gcc --prefix="$prefix" --enable-static --disable-shared \
            --enable-pic --enable-vp8 --enable-vp9 --disable-examples --disable-tools --disable-docs \
            --disable-unit-tests --enable-vp9-postproc --enable-runtime-cpu-detect \
            --extra-cflags="-mmacosx-version-min=$deployment_target" >"$1/_configure.log" 2>&1 \
            || { tail -40 "$1/_configure.log" >&2; exit 1; }
        make -j"$jobs" >"$1/_build.log" 2>&1 || { tail -40 "$1/_build.log" >&2; exit 1; }
        make install >/dev/null
    )
}

build_libarchive() {
    cmake_build "$1" -DENABLE_OPENSSL=OFF -DENABLE_MBEDTLS=OFF -DENABLE_NETTLE=OFF -DENABLE_LIBXML2=OFF \
        -DENABLE_EXPAT=OFF -DENABLE_ICONV=OFF -DENABLE_LZ4=OFF -DENABLE_LZO=OFF -DENABLE_LIBB2=OFF \
        -DENABLE_TAR=OFF -DENABLE_CPIO=OFF -DENABLE_CAT=OFF -DENABLE_UNZIP=OFF -DENABLE_TEST=OFF \
        -DENABLE_INSTALL=ON -DENABLE_ZSTD=ON -DENABLE_LZMA=ON -DENABLE_BZip2=ON -DENABLE_ZLIB=ON \
        -DENABLE_WERROR=OFF -DENABLE_ACL=ON -DENABLE_XATTR=ON
}

package_icu_data() {
    local icu_build="$1" source_data="$2" name="$3" entry="$4"
    local data_dir package_dir file
    data_dir="$work/icu-data-$name"
    package_dir="$work/icu-package-$name"
    mkdir -p "$data_dir/coll" "$package_dir"
    cp "$source_data/in/coll/ucadata-unihan.icu" "$data_dir/coll/ucadata.icu"
    cp "$source_data/in/nfc.nrm" "$data_dir/nfc.nrm"
    "$icu_build/bin/genrb" -q -R --ucadata "$data_dir/coll/ucadata.icu" \
        -d "$data_dir/coll" "$source_data/coll/root.txt" "$source_data/coll/en.txt" \
        "$source_data/coll/en_US_POSIX.txt" >"$package_dir/genrb.log" 2>&1 \
        || { cat "$package_dir/genrb.log" >&2; exit 1; }
    for file in coll/ucadata.icu nfc.nrm coll/root.res coll/en.res coll/en_US_POSIX.res; do
        echo "$file"
    done >"$package_dir/files.lst"
    "$icu_build/bin/pkgdata" -O "$icu_build/data/icupkg.inc" -p icudt78l -e "$entry" \
        -m static -s "$data_dir" -d "$package_dir" "$package_dir/files.lst" \
        >"$package_dir/pkgdata.log" 2>&1 \
        || { cat "$package_dir/pkgdata.log" >&2; exit 1; }
    cp "$package_dir/libicudt78l.a" "$lib/libicudata-$name.a"
}

build_icu() {
    local dir="$1" icu_source icu_build
    local apple_dir generated source build_log flags object
    icu_source="$dir/icu4c/source"
    icu_build="$dir/_build"
    apple_dir="$(unpack icu-apple)"
    keep_licenses icu-apple "$apple_dir"
    generated="$work/icu-generated"
    python3 "$root/Vendor/JSONCompare/prepare-icu.py" "$icu_source" "$generated"
    cp "$generated/include/unicode/tblcoll.h" "$icu_source/i18n/unicode/tblcoll.h"
    mkdir -p "$icu_build"
    (
        cd "$icu_build"
        "$icu_source/configure" --prefix="$prefix" --enable-static --disable-shared \
            --disable-extras --disable-icuio --disable-tests --disable-samples \
            --disable-dyload --with-data-packaging=archive \
            CFLAGS="-O2 $arch_flags" CXXFLAGS="-O2 $arch_flags" LDFLAGS="$arch_flags" \
            >"$dir/_configure.log" 2>&1 || { tail -40 "$dir/_configure.log" >&2; exit 1; }
        mkdir -p lib bin sbin
        for source in common i18n stubdata tools/toolutil tools/genrb tools/pkgdata; do
            build_log="$dir/_build-${source//\//-}.log"
            make -C "$source" -j"$jobs" >"$build_log" 2>&1 \
                || { tail -40 "$build_log" >&2; exit 1; }
        done
        make -C data icupkg.inc >"$dir/_build-data.log" 2>&1 \
            || { tail -40 "$dir/_build-data.log" >&2; exit 1; }
    )
    mkdir -p "$lib"
    cp "$icu_build/lib/libicuuc.a" "$icu_build/lib/libicui18n.a" "$lib/"
    package_icu_data "$icu_build" "$icu_source/data" current icudt78
    package_icu_data "$icu_build" "$apple_dir/icu/icu4c/source/data" legacy macease_legacy

    flags=(-O2 -std=c++17 -fPIC -arch arm64 "-mmacosx-version-min=$deployment_target"
        -DU_STATIC_IMPLEMENTATION
        -I"$generated/include" -I"$root/Vendor/JSONCompare/include"
        -I"$root/Vendor/JSONCompare" -I"$generated"
        -I"$icu_source/common" -I"$icu_source/i18n")
    for source in "$generated/externaliterator.cpp" "$generated/externalcompare.cpp" \
        "$root/Vendor/JSONCompare/JSONCompare.mm"; do
        object="$work/$(basename "$source").o"
        if [[ "$source" == *.mm ]]; then
            clang++ "${flags[@]}" -fobjc-arc -c "$source" -o "$object" \
                >"$dir/_compile-$(basename "$source").log" 2>&1 \
                || { tail -40 "$dir/_compile-$(basename "$source").log" >&2; exit 1; }
        else
            clang++ "${flags[@]}" -c "$source" -o "$object" \
                >"$dir/_compile-$(basename "$source").log" 2>&1 \
                || { tail -40 "$dir/_compile-$(basename "$source").log" >&2; exit 1; }
        fi
        merge_inputs+=("$object")
    done
}

for name in libdeflate xz zstd libogg libvorbis opus flac libwebp libaom dav1d libavif libjxl libvpx libarchive; do
    build "$name"
done
merge_inputs=()
lib="$prefix/lib"
build icu

cp "$(fetch cfr)" "$out/cfr.jar"
mkdir -p "$out/licenses/cfr"
cp "$(fetch cfr-license)" "$out/licenses/cfr/LICENSE"

echo "Packaging CNative.xcframework"
libraries=(
    libdeflate.a liblzma.a libzstd.a libogg.a libvorbis.a libvorbisenc.a libopus.a libFLAC.a
    libsharpyuv.a libwebp.a libwebpdemux.a libwebpmux.a libaom.a libdav1d.a libavif.a
    libjxl.a libjxl_cms.a libjxl_threads.a libhwy.a libbrotlicommon.a libbrotlienc.a libbrotlidec.a
    libvpx.a libarchive.a
    libicui18n.a libicuuc.a libicudata-current.a libicudata-legacy.a
)
for name in "${libraries[@]}"; do
    [[ -f "$lib/$name" ]] || { echo "error: $name was not built" >&2; exit 1; }
    merge_inputs+=("$lib/$name")
done
staging="$work/xcframework"
mkdir -p "$staging/include"
libtool -static -no_warning_for_no_symbols -o "$staging/libCNative.a" "${merge_inputs[@]}" 2>"$work/libtool.log" \
    || { cat "$work/libtool.log" >&2; exit 1; }
for header_dir in webp avif dav1d jxl vpx ogg vorbis opus FLAC; do
    cp -R "$prefix/include/$header_dir" "$staging/include/"
done
cp "$prefix/include/archive.h" "$prefix/include/archive_entry.h" "$prefix/include/libdeflate.h" \
    "$staging/include/"
cp "$root/Vendor/JSONCompare/include/JSONCompare.h" "$staging/include/"
cat >"$staging/include/module.modulemap" <<'MAP'
module CWebP {
    header "webp/encode.h"
    header "webp/decode.h"
    header "webp/demux.h"
    header "webp/mux.h"
    export *
}
module CAVIF {
    header "avif/avif.h"
    export *
}
module CDav1d {
    header "dav1d/dav1d.h"
    export *
}
module CJXL {
    header "jxl/encode.h"
    header "jxl/thread_parallel_runner.h"
    export *
}
module CVPX {
    header "vpx/vpx_encoder.h"
    header "vpx/vpx_decoder.h"
    header "vpx/vp8cx.h"
    header "vpx/vp8dx.h"
    export *
}
module COgg {
    header "ogg/ogg.h"
    export *
}
module CVorbis {
    header "vorbis/codec.h"
    header "vorbis/vorbisenc.h"
    export *
}
module COpus {
    header "opus/opus.h"
    export *
}
module CFLAC {
    header "FLAC/stream_encoder.h"
    export *
}
module CArchive {
    header "archive.h"
    header "archive_entry.h"
    export *
}
module CDeflate {
    header "libdeflate.h"
    export *
}
module CJSONCompare {
    header "JSONCompare.h"
    export *
}
MAP
xcodebuild -create-xcframework -library "$staging/libCNative.a" -headers "$staging/include" \
    -output "$out/CNative.xcframework" >/dev/null

"$root/scripts/build-hatchzip.sh"
"$root/scripts/generate-notices.sh"
rm -rf "$work" "$prefix"
echo "$stamp" >"$stamp_file"
echo "Native dependencies are ready in Vendor/build."
