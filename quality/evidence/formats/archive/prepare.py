#!/usr/bin/env python3
"""Prepare the Linux-only archive verification package from a checkout."""
import argparse
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("repo", type=Path)
parser.add_argument("native", type=Path)
parser.add_argument("output", type=Path)
parser.add_argument("--writer-ref")
args = parser.parse_args()
repo, native, output = args.repo.resolve(), args.native.resolve(), args.output.resolve()
evidence = Path(__file__).resolve().parent
kit = repo / "Packages/MacEaseKit"
formats = output / "Sources/Formats"
tests = output / "Tests/FormatsTests"
for directory in (formats, tests, output / "Sources/CArchive"):
    directory.mkdir(parents=True, exist_ok=True)


def portable(text):
    return (text.replace("import Darwin", "import Glibc")
            .replace("st_mtimespec", "st_mtim")
            .replace("st_ctimespec", "st_ctim")
            .replace("st_atimespec", "st_atim"))


writer_path = "Packages/MacEaseKit/Sources/Formats/Archive/ArchiveWriter.swift"
writer = ((repo / writer_path).read_text() if args.writer_ref is None else
          subprocess.check_output(["git", "show", f"{args.writer_ref}:{writer_path}"], cwd=repo, text=True))
(formats / "ArchiveWriter.swift").write_text(portable(writer))
for source in ("Archive/ArchiveFormat.swift", "Common/FormatError.swift"):
    shutil.copy2(kit / "Sources/Formats" / source, formats / Path(source).name)
shutil.copy2(evidence / "Scaffolding.swift", formats / "Scaffolding.swift")
for name in ("ExtractionOracle.swift", "FileDescriptorTests.swift"):
    shutil.copy2(evidence / name, tests / name)
shutil.copy2(kit / "Tests/FormatsTests/TestTemporaryFolders.swift", tests / "TestTemporaryFolders.swift")
suite = portable((kit / "Tests/FormatsTests/ArchiveWriterTests.swift").read_text())
original = '_ = try ArchiveExtractor.extract(archive, into: output, rawName: "output", password: nil) { _ in }'
assert suite.count(original) == 1
(tests / "ArchiveWriterTests.swift").write_text(suite.replace(original, "try extractForTest(archive, into: output)"))
(output / "Sources/CArchive/module.modulemap").write_text(
    'module CArchive [system] {\n'
    f'  header "{native}/include/archive.h"\n  header "{native}/include/archive_entry.h"\n'
    '  export *\n}\n')
(output / "Package.swift").write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "ArchiveHarness", targets: [
    .systemLibrary(name: "CArchive"),
    .target(name: "Formats", dependencies: ["CArchive"], swiftSettings: [.unsafeFlags(["-warnings-as-errors"])], linkerSettings: [.unsafeFlags(["-L''' + str(native / 'lib') + '''", "-larchive", "-llzma", "-lzstd", "-lz"])]),
    .testTarget(name: "FormatsTests", dependencies: ["Formats", "CArchive"], swiftSettings: [.unsafeFlags(["-warnings-as-errors"])])
])
''')
print(output)
