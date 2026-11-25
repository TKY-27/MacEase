#!/usr/bin/env python3
"""Prepare the Linux-only Ogg verification package from a checkout."""
import argparse
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("repo", type=Path)
parser.add_argument("native", type=Path)
parser.add_argument("output", type=Path)
parser.add_argument("--ogg-ref")
args = parser.parse_args()
repo, native, output = args.repo.resolve(), args.native.resolve(), args.output.resolve()
evidence = Path(__file__).resolve().parent
kit = repo / "Packages/MacEaseKit"
sources = kit / "Sources"
formats = output / "Sources/Formats"
tests = output / "Tests/FormatsTests"
for relative in ("Sources/Formats", "Sources/COgg", "Sources/COpus", "Sources/CVorbis",
                 "Sources/NativeShims/include", "Tests/FormatsTests/Resources", "fixtures"):
    (output / relative).mkdir(parents=True, exist_ok=True)
for relative in ("Audio/OggAudio.swift", "Containers/Ogg.swift", "Codecs/Opus.swift", "Codecs/Vorbis.swift",
                 "Audio/AudioTags.swift", "Audio/AudioMetadata.swift", "Audio/PCMSource.swift",
                 "Common/ByteOrder.swift", "Common/FormatError.swift"):
    shutil.copy2(sources / "Formats" / relative, formats / Path(relative).name)
if args.ogg_ref:
    original = "Packages/MacEaseKit/Sources/Formats/Containers/Ogg.swift"
    (formats / "Ogg.swift").write_text(subprocess.check_output(
        ["git", "show", f"{args.ogg_ref}:{original}"], cwd=repo, text=True))
fileio = (sources / "Formats/Containers/FileIO.swift").read_text()
(formats / "FileIO.swift").write_text(fileio.replace(
    "try autoreleasepool { try read(upToCount: count) }", "try read(upToCount: count)"))
model = (sources / "Formats/Containers/MediaModel.swift").read_text()
codec = model[model.index("public enum MediaCodec"):model.index("public struct VideoDisplayGeometry")]
skipped = model[model.index("public enum SkippedTrackKind"):model.index("public protocol MediaMuxer")]
(formats / "PortableSupport.swift").write_text("import Foundation\n" + codec + skipped + '''
struct DecodedImageBudget { static let maximumBytes = 100_000_000 }
extension String {
    init(localized value: String, comment: String = "") { self = value }
}
''')
shims = (sources / "NativeShims/NativeShims.c").read_text()
(output / "Sources/NativeShims/NativeShims.c").write_text('#include "NativeShims.h"\n' +
    shims[shims.index("int macease_opus_set_bitrate"):shims.index("static vpx_codec_iface_t")])
(output / "Sources/NativeShims/include/NativeShims.h").write_text('''#include <opus/opus.h>
int macease_opus_set_bitrate(OpusEncoder *encoder, opus_int32 bitrate);
int macease_opus_set_complexity(OpusEncoder *encoder, opus_int32 complexity);
int macease_opus_get_lookahead(OpusEncoder *encoder, opus_int32 *samples);
''')
for module, headers in (("COgg", ["ogg/ogg.h"]), ("COpus", ["opus/opus.h"]),
                        ("CVorbis", ["vorbis/codec.h", "vorbis/vorbisenc.h"])):
    (output / "Sources" / module / "module.modulemap").write_text(
        f"module {module} [system] {{\n" +
        "".join(f'  header "{native}/include/{header}"\n' for header in headers) + '  export *\n}\n')
shutil.copy2(kit / "Tests/FormatsTests/OggPageTests.swift", tests / "OggPageTests.swift")
fixture = (kit / "Tests/FormatsTests/ContainerFixtures.swift").read_text()
(tests / "ContainerFixtures.swift").write_text(fixture[:fixture.index("    static func packets")] + "}\n")
suite = (kit / "Tests/FormatsTests/OggFLACTests.swift").read_text().replace("import AVFoundation\n", "")
for name in ("decodesThirdPartyFLACWithItsArtwork", "flacWriterIsLosslessAndTagged"):
    start = suite.index("    @Test func " + name)
    cursor = suite.index("{", start) + 1
    depth = 1
    while depth:
        if suite[cursor] == "{": depth += 1
        elif suite[cursor] == "}": depth -= 1
        cursor += 1
    suite = suite[:start] + suite[cursor:]
(tests / "OggFLACTests.swift").write_text(suite)
audio = (kit / "Tests/FormatsTests/AudioFixtures.swift").read_text()
delay = audio[audio.index("    static func delay"):audio.index("    /// Mean segment SNR")]
(tests / "AudioFixtures.swift").write_text("import Foundation\nenum AudioFixtures {\n" + delay + "}\n")
for name in ("ffmpeg-vorbis.ogg", "ffmpeg-opus.opus"):
    shutil.copy2(kit / "Tests/FormatsTests/Resources" / name, tests / "Resources" / name)
for name in ("OggBufferingProbe.swift", "OggStreamRegression.swift"):
    contents = (evidence / name).read_text().replace(
        "/workspace/scratch/92211793ca84/ogg-harness/", str(output / "fixtures") + "/")
    (tests / name).write_text(contents)
include = str(native / "include")
libs = [str(native / "lib" / name) for name in ("libvorbisenc.a", "libvorbis.a", "libogg.a", "libopus.a")]
(output / "Package.swift").write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "OggAudit", targets: [
    .systemLibrary(name: "COgg"), .systemLibrary(name: "COpus"), .systemLibrary(name: "CVorbis"),
    .target(name: "NativeShims", cSettings: [.unsafeFlags(["-I''' + include + '''"])]),
    .target(name: "Formats", dependencies: ["COgg", "COpus", "CVorbis", "NativeShims"], swiftSettings: [.unsafeFlags(["-warnings-as-errors", "-Xcc", "-I''' + include + '''"])], linkerSettings: [.unsafeFlags([''' + ', '.join('"' + lib + '"' for lib in libs) + ''', "-lm"])]),
    .testTarget(name: "FormatsTests", dependencies: ["Formats"], resources: [.copy("Resources")], swiftSettings: [.unsafeFlags(["-Xcc", "-I''' + include + '''"])])
])
''')
print(output)
