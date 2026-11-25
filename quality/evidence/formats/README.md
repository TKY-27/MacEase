# Portable Formats validation checkpoint

These are Linux verification harnesses, not macOS acceptance. They do not build
the application, the full Swift package, the Apple SDK paths, or the shipped
native dependency configuration. No product PR was submitted for these fixes
without the macOS gate.

## Source state

- Baseline: `1bf5681919034a3a79b9badff01232399ce6e1f8`.
- Archive: `quality/archive-source-validation`,
  `379aad37467e4c275b65414b9086852b1ea91117`.
- Ogg: `quality/ogg-page-granules`,
  `9f7444a0a9be1a61de1b3ea31e996d641e43132c`.
- Opus: `quality/opus-empty-packets`,
  `abb9cf4e8d70f9aaa8bd2261400fa78074eac436`.
- All three product diffs received independent reviews from `audit_core` and
  `audit_app`. The archive's initial implicit-close padding finding was fixed
  and both reviewers re-reviewed the final abort/descriptor ownership change.
- Runtime: Swift 6.2 release, Linux x86_64. Tests use release compilation;
  production target warnings are errors. Timings in logs are test timings,
  not performance benchmarks.

## Native inputs

The commit IDs above are local validation commits. Tree-identical published
commits are `446426548ca15a8e07b3f672eeb6cbfc7ec0e934` (archive),
`00faf613791076528d432e0f6b45508a8e795ca5` (Ogg), and
`8d2e50dc4183bdda3a25a93394423d6b3b294de3` (Opus). Use the corresponding branch
or remote commit to restore a fresh checkout.

All downloaded archives were SHA-256 verified against `Vendor/deps.lock`.

| Dependency | Version | SHA-256 |
| --- | --- | --- |
| libarchive | 3.8.10 | `56cad765459d5ee25a3b761f90c47d99379d28297fbfb72d908880d6b875fb96` |
| xz | 5.8.4 | `4ce24038fd4221e0d13bc1a2de7a4db56e90b92b3bf75321f6c14be73f65de4b` |
| libogg | 1.3.6 | `5c8253428e181840cd20d41f3ca16557a9cc04bad4a3d04cce84808677fa1061` |
| opus | 1.6.1 | `6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1` |
| libvorbis | 1.3.7 | `b33cc4934322bcbf6efcbacf49e3ca01aadbea4114ec9589d1b1e9d20f72954b` |

Download the URLs in the lock file using `curl --fail --location`, verify the
hashes above using `sha256sum`, and extract each archive with `tar -xf`. The
configure scripts are included in the release archives; generating them is not
necessary. A C compiler, make, Python 3, Swift 6.2, and zlib/zstd development
libraries are needed. These are the configure/build recipes used:

```sh
# In an archive harness directory, after extracting xz and libarchive:
archive_native="$PWD/native"
./xz-5.8.4/configure --prefix="$archive_native" --disable-shared \
  --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo \
  --disable-scripts --disable-doc
make -j4
make install
mkdir libarchive-build
cd libarchive-build
CPPFLAGS="-I$archive_native/include" LDFLAGS="-L$archive_native/lib" \
  ../libarchive-3.8.10/configure --prefix="$archive_native" --disable-shared \
  --disable-bsdtar --disable-bsdcpio --disable-bsdcat --disable-bsdunzip \
  --without-bz2lib --without-lz4 --without-iconv --without-openssl \
  --without-xml2 --without-expat --without-bsdxml --disable-xattr --disable-acl
make -j4
make install
```

This archive configuration enables the pinned liblzma plus system zlib/zstd.
It deliberately does not reproduce the application's macOS bzip2, ACL, xattr,
or CMake configuration. ZIP, 7z, TAR, and gzip TAR writer tests ran against the
pinned libarchive library built above.

```sh
# In a separate Ogg harness directory, after extracting the three archives:
ogg_native="$PWD/native"
cd libogg-1.3.6
./configure --prefix="$ogg_native" --disable-shared --enable-static --disable-docs
make -j4
make install
cd ../opus-1.6.1
./configure --prefix="$ogg_native" --disable-shared --enable-static \
  --disable-doc --disable-extra-programs
make -j4
make install
cd ../libvorbis-1.3.7
./configure --prefix="$ogg_native" --with-ogg="$ogg_native" \
  --disable-shared --enable-static --disable-docs --disable-examples
make -j4
make install
```

## Archive adapter and commands

`archive/prepare.py REPO NATIVE_PREFIX OUTPUT` creates a standalone SwiftPM
package from the archive branch. The complete `ArchiveWriter.swift`,
`ArchiveFormat.swift`, `FormatError.swift`, `ArchiveWriterTests.swift`, and
`TestTemporaryFolders.swift` come from that checkout.

The only writer/test platform substitutions are Darwin→Glibc and
`st_{a,m,c}timespec`→`st_{a,m,c}tim`. The happy-path test extraction call uses the
retained `ExtractionOracle.swift` instead of the production extractor, whose
larger dependency graph needs macOS. `Scaffolding.swift` supplies the writer's
existing error-message lookup, duplicate-root error case, Linux `C.UTF-8` locale,
and direct Foundation read without Darwin's autorelease pool.

```sh
python3 archive/prepare.py /path/to/archive-checkout /path/to/archive/native /tmp/archive-check
swift test --package-path /tmp/archive-check -c release --filter ArchiveWriterTests
swift test --package-path /tmp/archive-check -c release --filter FileDescriptorTests
```

Observed results:

- `current-tests.log`: 7 new test functions, 13 parameterized cases pass.
- `fd-tests.log`: 64 expected failed writes, `/proc/self/fd` count 7 before and
  7 after. This Linux-only descriptor test is retained as harness scaffolding.
- `baseline-tests.log`: all 7 selected mutation cases fail against the old
  writer. The failed baseline TAR is 2,098,688 bytes for a 2,097,152-byte input,
  demonstrating implicit padding. The same assertion passes after the fix.

To reproduce the baseline, prepare a different output directory using the new
tests but the old writer:

```sh
python3 archive/prepare.py /path/to/archive-checkout /path/to/archive/native /tmp/archive-baseline \
  --writer-ref 1bf5681919034a3a79b9badff01232399ce6e1f8
swift test --package-path /tmp/archive-baseline -c release \
  --filter 'shrinkingFileIsRejected|sameSizeEditWithRestoredModificationTimeIsRejected|unreadFileReplacedBySymlinkIsRejected|unreadFileReplacedWithSameSizeIsRejected'
```

That command is expected to fail. Do not run the baseline FIFO test: the old
writer blocks opening the FIFO. Current FIFO rejection is included in the green
run. The source consistency guarantee is per regular file, not a transactional
snapshot of an entire directory tree.

## Ogg adapter and commands

`ogg/prepare.py REPO NATIVE_PREFIX OUTPUT` copies the complete Ogg container,
Ogg audio reader/writer, Opus/Vorbis codec, audio metadata/tags, PCM source,
byte-order, and format-error production files. `Ogg.swift` and the new
`OggPageTests.swift` are byte-identical to the checkout.

The adapter retains the exact `MediaCodec` and skipped-stream enum declarations
without the unrelated CoreMedia/CoreGraphics types. It isolates the three
existing Opus C wrappers, provides English `String(localized:)` construction,
copies the unchanged image-budget constant needed to compile audio artwork,
and removes the Darwin autorelease pool around file reads. These substitutions
do not alter the page validation, decoding, pending PCM buffer, or codec code.

The Ogg portions of existing `OggFLACTests` are copied unchanged. Its two
AVFoundation/FLAC tests are omitted from this Linux-only package; no repository
tests are removed or changed. The adapter copies the exact delay helper, the
two third-party Ogg fixtures, and the fixture support without unrelated demuxer
methods. `OggStreamRegression.swift` is a harness-only Opus/Vorbis chain check.

```sh
python3 ogg/prepare.py /path/to/ogg-checkout /path/to/ogg/native /tmp/ogg-check
swift test --package-path /tmp/ogg-check -c release \
  --filter 'OggPageTests|OggFLACTests|OggStreamRegression'
```

`current-tests.log`: 10 functions, 15 parameterized cases pass: 6 new page cases,
7 existing codec cases, and 2 chain cases. The new positive tests cover internal
packet granule `-1` within a valid page and continued 70,000-character comment
packets for both Vorbis and Opus. Existing checks cover third-party fixtures,
sample alignment, trim, surround channel order, headers, and unsupported codecs.

```sh
python3 ogg/prepare.py /path/to/ogg-checkout /path/to/ogg/native /tmp/ogg-baseline \
  --ogg-ref 1bf5681919034a3a79b9badff01232399ce6e1f8
swift test --package-path /tmp/ogg-baseline -c release \
  --filter 'OggPageTests|OggFLACTests|OggStreamRegression'
swift test --package-path /tmp/ogg-baseline -c release --filter OggBufferingProbe
```

The first command is expected to fail in all 3 new negative-page cases; positive
and existing controls pass. The second measures the baseline's first returned
PCM buffer for CRC-valid pages containing valid Opus packets but invalid page
granules. `probe.log` records:

| Packet count | File bytes | Correct granules: first PCM bytes | Missing granules: first PCM bytes |
| --- | --- | --- | --- |
| 100 | 525 | 382,752 | 382,752 |
| 1,000 | 4,206 | 977,952 | 3,838,752 |
| 10,000 | 41,178 | 977,952 | 38,398,752 |

These are returned Float32 sample counts multiplied by four, not process RSS
measurements. The old reader retains decoded samples until a nonnegative page
granule or EOF. The fix rejects the malformed completed page before delivering
its first packet. The original buffering probe intentionally describes baseline
behavior and should not be included in the green filter.

The format rule comes from RFC 3533 section 6 and RFC 7845 section 4:
<https://www.rfc-editor.org/rfc/rfc3533.html> and
<https://www.rfc-editor.org/rfc/rfc7845.html>. Pinned libogg's
`ogg_page_packets` counts completed lacing entries; internal packets before the
last completed packet on a valid page still receive granule `-1`.

## Empty Opus packet validation

The separate Opus branch adds only a positive-length condition to the existing
representable-packet-size guard. Empty received packets previously entered
libopus's packet-loss concealment path and generated 5,760 frames per channel.
RFC 7845 section 3 requires zero-octet Ogg Opus packets to be treated as malformed;
section 4.1 permits nonempty packets with a TOC byte to represent concealment.
The same decoder serves received Matroska/WebM packets. No caller intentionally
passes an empty payload to request concealment.

`opus/probe.log` and `OpusEmptyPacketProbe.swift` preserve the reproduction using
pinned opus 1.6.1: an empty packet generated 5,760 frames, a CRC-valid Ogg empty
packet returned 5,448 frames after pre-skip, and the valid nonempty `[0xF8]`
concealment packet returned 960 frames. These observations were made before the
Opus fix, with the Ogg page fix present. This is an input-validation correction;
there is no new upper packet-size limit.

The exact independent baseline/current test setup reuses the Ogg adapter:

```sh
python3 ogg/prepare.py /path/to/ogg-checkout /path/to/ogg/native /tmp/opus-check \
  --ogg-ref 1bf5681919034a3a79b9badff01232399ce6e1f8
cp /path/to/opus-checkout/Packages/MacEaseKit/Tests/FormatsTests/OpusPacketTests.swift \
  /tmp/opus-check/Tests/FormatsTests/
swift test --package-path /tmp/opus-check -c release \
  --filter 'OpusPacketTests|OggFLACTests|OggStreamRegression'
# The baseline above fails the two empty-payload cases as expected.
cp /path/to/opus-checkout/Packages/MacEaseKit/Sources/Formats/Codecs/Opus.swift \
  /tmp/opus-check/Sources/Formats/
swift test --package-path /tmp/opus-check -c release \
  --filter 'OpusPacketTests|OggFLACTests|OggStreamRegression'
```

The Ogg checkout still contains the old Opus decoder, so the first run is a
baseline. `opus/baseline-tests.log` records four failed assertions in two
parameterized cases: direct decoding and Ogg decoding must both reject empty
mono/stereo packets. Both valid encoded-silence and TOC-only concealment controls
pass before and after the fix. `opus/current-tests.log` records 9 functions,
13 parameterized cases passing with the baseline Ogg container, demonstrating
that the two fixes are independent. Both reviewers independently ran the 4 new
Opus cases against source/test files identical to the final candidate.

The cumulative check then copied the Ogg candidate into that same harness:

```sh
cp /path/to/ogg-checkout/Packages/MacEaseKit/Sources/Formats/Containers/Ogg.swift \
  /tmp/opus-check/Sources/Formats/
swift test --package-path /tmp/opus-check -c release \
  --filter 'OggPageTests|OpusPacketTests|OggFLACTests|OggStreamRegression'
```

`opus/cumulative-tests.log` records 12 functions, 19 parameterized cases passing
with both fixes together. Negative page granules are rejected before packet
delivery, while an empty packet on an otherwise valid page reaches the shared
decoder's separate validation. Positive continuation, timing, silence, and
concealment paths remain covered. This remains Linux-only verification.

## Adapter replay

The retained `prepare.py` adapters were each used to create a fresh package and
rerun the corresponding green filter against the already-built pinned native
libraries. `archive/adapter-check.log` and `ogg/adapter-check.log` record those
runs. Downloaded source trees, build outputs, and binaries are excluded from
this checkpoint; source-of-truth product files stay on their separate branches.
