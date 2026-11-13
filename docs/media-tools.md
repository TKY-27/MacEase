# Bundled media tools

MacEase remains MIT licensed. Its media download and local MP3 workflows launch independent
third-party executables from `Contents/Resources/media-tools/bin`. It does not
link FFmpeg into the MacEase app. Local MP3 encoding streams PCM through a pipe
into libmp3lame, with no automatic fallback or intermediate audio file.
These executables retain their upstream licenses. GPL and nonfree FFmpeg
features are disabled. LGPL FFmpeg and LAME are the isolated executable exception
recorded in SPEC sections 22–23 and ADRs 0052–0053.
Gallery downloads use the unmodified GPL-2.0-only gallery-dl command-line
program as a separate process (ADR 0057). Its implementation is neither linked
nor copied into the MIT application. Its exact source, license and required
Requests dependencies are included in the matching source distribution.

## Build

On an Apple Silicon Mac with Xcode command line tools, CMake, Meson, Ninja and
pkg-config:

```sh
scripts/build-media-tools.sh
```

The script verifies every archive against `Vendor/media-tools.lock`, then builds
CPython, OpenSSL, FFmpeg, LAME, libvpx, dav1d and Opus from the exact pinned sources.
Node LTS is the pinned official arm64 executable. Its official LICENSE includes
its third-party dependency notices. yt-dlp is installed from its
Unlicense Python source distribution, rather than its GPL-containing macOS
standalone executable. The pinned EJS wheel contains offline solver JavaScript;
its matching source distribution is included. No package manager or external
Python is required at runtime. Python's TLS verifier uses macOS's
`/etc/ssl/cert.pem`; OpenSSL and Python do not need Homebrew libraries.

Python intentionally omits interactive, database, Tk, ctypes, LZMA and Zstandard
optional modules. Download requests use the included standard urllib backend.
The host uses `python3 -I -B -m yt_dlp`, ignores user configuration and plugins,
passes explicit Node and FFmpeg paths, and never self-updates these tools.
Image galleries use `python3 -I -B -m gallery_dl` with configuration discovery,
postprocessors and interactive authentication disabled. Only supported image
files are accepted; downloads are verified before publishing a new folder.
`MacEase Source.json` records the requested gallery page, retrieval time and saved
filenames. This records a download origin, not authorship or authenticity.

FFmpeg uses native VideoToolbox H.264 and AAC encoders, VP9 through libvpx,
AV1 decoding through dav1d, Opus through libopus, MP3 through libmp3lame, and
native PCM/FLAC encoders. HTTPS and encrypted HLS use the macOS Secure Transport
TLS backend, without linking FFmpeg to OpenSSL.
FFmpeg and LAME are shared libraries with relative install names. Users can
replace these independent tools with compatible modified builds. Signing
replacement executables ad hoc can be necessary under macOS code validation.
No MacEase source object relinking is needed.

Node 26.13.0 is the official Lithium LTS release, and exceeds yt-dlp's Node 22
minimum. yt-dlp executes its solver using Node's `--permission` mode over stdin.
Node was selected over Deno because its official distribution includes a complete
third-party license document, and over QuickJS because it avoids solver temporary
files. The arm64 Node executable is approximately 141 MiB.

## Source distribution

`Vendor/build/media-tools-sources.tar.xz` contains the exact source archives,
build script, lock manifest and this document. Release packaging copies it
alongside the signed DMG. It must be published on the same release as the DMG.
The application contains the manifest, build configuration and license texts.

To rebuild from the source archive, extract it, create `Vendor/src/media-tools`,
copy `sources/*` there and run the included script from that directory's parent
repository layout. The script also downloads pinned Node. The included LAME
patch removes an export for the removed
`lame_init_old` API, which otherwise fails current Apple linking. No algorithm
code is changed. All configure options are preserved in the build script.
FFmpeg's expanded configuration is also included with the runtime.

Upstream references: [yt-dlp](https://github.com/yt-dlp/yt-dlp),
[EJS setup](https://github.com/yt-dlp/yt-dlp/wiki/EJS),
[CPython configuration](https://docs.python.org/3.14/using/configure.html),
[FFmpeg licensing](https://ffmpeg.org/legal.html), and
[Node permissions](https://nodejs.org/api/permissions.html).
