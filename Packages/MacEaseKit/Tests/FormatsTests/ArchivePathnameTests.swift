import CArchive
import Darwin
import Foundation
import Testing

@testable import Engine
@testable import Formats

@Suite struct ArchivePathnameTests {
    private struct CP932Pair: Decodable {
        let bytes: [UInt8]
        let expected: String?
    }

    private func fixture(_ body: String, extensionName: String = "zip") throws -> (URL, URL) {
        let folder = URL(fileURLWithPath: "/private/tmp").appending(path: "archive-names-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        TestTemporaryFolders.register(folder)
        let source = folder.appending(path: "legacy.\(extensionName)")
        let python = Process()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        python.arguments = [
            "-c",
            """
            import io, pathlib, struct, sys, tarfile, zipfile, zlib
            source = pathlib.Path(sys.argv[1])
            class RawName(zipfile.ZipInfo):
                def __init__(self, name):
                    super().__init__('placeholder')
                    self.raw_name = name
                def _encodeFilenameFlags(self):
                    return self.raw_name, self.flag_bits & ~0x800
            def write_zip(names):
                with zipfile.ZipFile(source, 'w') as archive:
                    for name in names:
                        archive.writestr(RawName(name), b'legacy payload')
            """ + "\n" + body, source.path,
        ]
        try python.run()
        python.waitUntilExit()
        try #require(python.terminationStatus == 0)
        let output = folder.appending(path: "output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        return (source, output)
    }

    @Test(arguments: ["zip", "tar"])
    func cp932NestedPathsExtractWithJapaneseNames(_ extensionName: String) throws {
        let body =
            extensionName == "zip"
            ? "write_zip(['資料/日本語.txt'.encode('cp932')])"
            : """
            with tarfile.open(source, 'w', format=tarfile.USTAR_FORMAT, encoding='cp932') as archive:
                header = tarfile.TarInfo('資料/日本語.txt')
                header.size = len(b'legacy payload')
                archive.addfile(header, io.BytesIO(b'legacy payload'))
            """
        let (source, output) = try fixture(body, extensionName: extensionName)
        try ArchiveListing.verify(source, prefersJapanese: true)
        let layout = try ArchiveExtractor.extract(
            source, into: output, rawName: "legacy", password: nil, prefersJapanese: true
        ) { _ in }
        #expect(layout == .entries)
        #expect(try Data(contentsOf: output.appending(path: "資料/日本語.txt")) == Data("legacy payload".utf8))
        if extensionName == "zip" {
            #expect(try ArchiveBrowserZIP.list(source, prefersJapanese: true).map(\.path) == ["資料/日本語.txt"])
            let selected = output.appending(path: "selected.txt")
            try ArchiveBrowserZIP.extract(
                source, ordinal: 0, to: selected, password: nil, limit: 100, prefersJapanese: true)
            #expect(try Data(contentsOf: selected) == Data("legacy payload".utf8))
        }
    }

    @Test func unflaggedUTF8WinsOverCP932() throws {
        let (source, output) = try fixture("write_zip(['¢.txt'.encode('utf-8'), '資料.txt'.encode('utf-8')])")
        #expect(try ArchiveBrowserZIP.list(source, prefersJapanese: true).map(\.path) == ["¢.txt", "資料.txt"])
        let layout = try ArchiveExtractor.extract(
            source, into: output, rawName: "legacy", password: nil, prefersJapanese: true
        ) { _ in }
        #expect(layout == .entries)
        #expect(try Data(contentsOf: output.appending(path: "¢.txt")) == Data("legacy payload".utf8))
        #expect(try Data(contentsOf: output.appending(path: "資料.txt")) == Data("legacy payload".utf8))
    }

    @Test func cp932VendorAndHalfwidthCharactersRemainSupported() throws {
        let (source, output) = try fixture("write_zip([bytes.fromhex('fa 40 a6 2e 74 78 74')])")
        #expect(try ArchiveBrowserZIP.list(source, prefersJapanese: true).map(\.path) == ["ⅰｦ.txt"])
        let layout = try ArchiveExtractor.extract(
            source, into: output, rawName: "legacy", password: nil, prefersJapanese: true
        ) { _ in }
        #expect(layout == .entries)
        #expect(try Data(contentsOf: output.appending(path: "ⅰｦ.txt")) == Data("legacy payload".utf8))
    }

    @Test func everyDoubleByteAssignmentMatchesWindowsCP932() throws {
        let (reference, _) = try fixture(
            """
            import json, unicodedata
            pairs = []
            for lead in list(range(0x81, 0xa0)) + list(range(0xe0, 0xfd)):
                for trail in range(0x40, 0xfd):
                    encoded = bytes([lead, trail])
                    try:
                        expected = encoded.decode('cp932', errors='strict')
                        if any(unicodedata.category(character) in ('Cc', 'Co') for character in expected):
                            expected = None
                    except UnicodeDecodeError:
                        expected = None
                    pairs.append({'bytes': list(encoded), 'expected': expected})
            source.write_text(json.dumps(pairs))
            """, extensionName: "json")
        let pairs = try JSONDecoder().decode([CP932Pair].self, from: Data(contentsOf: reference))
        #expect(pairs.count == 11_340)
        let entry = try #require(archive_entry_new())
        defer { archive_entry_free(entry) }
        try ArchiveListing.inUTF8Locale {
            for pair in pairs {
                let name = pair.bytes.map { CChar(bitPattern: $0) } + [0]
                name.withUnsafeBufferPointer { archive_entry_copy_pathname(entry, $0.baseAddress) }
                if let expected = pair.expected {
                    let decoded = try ArchivePathname.decode(entry, encoding: .cp932)
                    #expect(decoded == expected, "\(pair.bytes)")
                } else {
                    #expect(throws: ArchiveError.unsupportedNameEncoding, "\(pair.bytes)") {
                        try ArchivePathname.decode(entry, encoding: .cp932)
                    }
                }
            }
        }
    }

    @Test func longCommentsDoNotBlockLegacyNameValidation() throws {
        let (source, output) = try fixture(
            """
            write_zip(['資料.txt'.encode('cp932')])
            with zipfile.ZipFile(source, 'a') as archive:
                archive.comment = b'x' * 65535
            """)
        #expect(try ArchiveBrowserZIP.list(source, prefersJapanese: true).map(\.path) == ["資料.txt"])
        let layout = try ArchiveExtractor.extract(
            source, into: output, rawName: "legacy", password: nil, prefersJapanese: true
        ) { _ in }
        #expect(layout == .entries)
        #expect(try Data(contentsOf: output.appending(path: "資料.txt")) == Data("legacy payload".utf8))
    }

    @Test func zip64LocalOffsetsRetainFilenameValidation() throws {
        let (source, output) = try fixture(
            """
            write_zip(['資料.txt'.encode('cp932')])
            payload = bytearray(source.read_bytes())
            central = payload.index(b'PK\\x01\\x02')
            name_length = struct.unpack_from('<H', payload, central + 28)[0]
            field = struct.pack('<HHQQQ', 1, 24, len(b'legacy payload'), len(b'legacy payload'), 0)
            struct.pack_into('<H', payload, central + 6, 45)
            struct.pack_into('<I', payload, central + 20, 0xffffffff)
            struct.pack_into('<I', payload, central + 24, 0xffffffff)
            struct.pack_into('<I', payload, central + 42, 0xffffffff)
            struct.pack_into('<H', payload, central + 30, len(field))
            position = central + 46 + name_length
            payload[position:position] = field
            end = len(payload) - 22
            struct.pack_into('<I', payload, end + 12, end - central)
            source.write_bytes(payload)
            """)
        #expect(try ArchiveBrowserZIP.list(source, prefersJapanese: true).map(\.path) == ["資料.txt"])
        let layout = try ArchiveExtractor.extract(
            source, into: output, rawName: "legacy", password: nil, prefersJapanese: true
        ) { _ in }
        #expect(layout == .entries)
        #expect(try Data(contentsOf: output.appending(path: "資料.txt")) == Data("legacy payload".utf8))
    }

    @Test func unicodePathExtraOverridesAnUnreadableLegacyName() throws {
        let (source, output) = try fixture(
            """
            raw_name = bytes.fromhex('63 61 66 82 2e 74 78 74')
            unicode_name = '資料.txt'.encode('utf-8')
            field = b'\\x01' + struct.pack('<I', zlib.crc32(raw_name)) + unicode_name
            header = RawName(raw_name)
            header.extra = struct.pack('<HH', 0x7075, len(field)) + field
            with zipfile.ZipFile(source, 'w') as archive:
                archive.writestr(header, b'legacy payload')
            """)
        #expect(try ArchiveBrowserZIP.list(source, prefersJapanese: true).map(\.path) == ["資料.txt"])
        let layout = try ArchiveExtractor.extract(
            source, into: output, rawName: "legacy", password: nil, prefersJapanese: true
        ) { _ in }
        #expect(layout == .entries)
        #expect(try Data(contentsOf: output.appending(path: "資料.txt")) == Data("legacy payload".utf8))
    }

    @Test(
        arguments: [
            "63 61 66 82 2e 74 78 74", "82", "81 ad", "81 7f", "f0 40", "01 82 a0",
            "85 40", "86 40", "87 9e", "88 40", "eb 51",
        ], [false, true])
    func invalidCP932ZIPNamesUseCP437(_ hex: String, prefersJapanese: Bool) throws {
        let (source, output) = try fixture(
            """
            raw = bytes.fromhex('\(hex)')
            write_zip([raw])
            source.with_suffix('.expected').write_text(raw.decode('cp437'), encoding='utf-8')
            """)
        let expected = try String(
            contentsOf: source.deletingPathExtension().appendingPathExtension("expected"), encoding: .utf8)
        try ArchiveListing.verify(source, prefersJapanese: prefersJapanese)
        let layout = try ArchiveExtractor.extract(
            source, into: output, rawName: "legacy", password: nil, prefersJapanese: prefersJapanese
        ) { _ in }
        #expect(layout == .entries)
        #expect(try Data(contentsOf: output.appending(path: expected)) == Data("legacy payload".utf8))
        #expect(try ArchiveBrowserZIP.list(source, prefersJapanese: prefersJapanese).map(\.path) == [expected])
    }

    @Test func oneInvalidCP932NameSelectsCP437ForTheWholeZIP() throws {
        let (source, output) = try fixture("write_zip(['資料.txt'.encode('cp932'), b'bad\\x82.txt'])")
        let layout = try ArchiveExtractor.extract(
            source, into: output, rawName: "legacy", password: nil, prefersJapanese: true
        ) {
            _ in
        }
        #expect(layout == .entries)
        #expect(try Data(contentsOf: output.appending(path: "Äæù┐.txt")) == Data("legacy payload".utf8))
        #expect(try Data(contentsOf: output.appending(path: "badé.txt")) == Data("legacy payload".utf8))
        #expect(try ArchiveBrowserZIP.list(source, prefersJapanese: true).map(\.path) == ["Äæù┐.txt", "badé.txt"])
        let selected = output.appending(path: "selected")
        try ArchiveBrowserZIP.extract(
            source, ordinal: 0, to: selected, password: nil, limit: 100, prefersJapanese: true)
        #expect(try Data(contentsOf: selected) == Data("legacy payload".utf8))
    }

    @Test(arguments: ["cp932", "cp437-valid", "cp437-invalid"], [false, true])
    func nativeAndBrowserUseTheSameExplicitLanguagePreference(_ kind: String, prefersJapanese: Bool) throws {
        let expression: String
        let expected: String
        switch kind {
        case "cp932":
            expression = "'資料.txt'.encode('cp932')"
            expected = prefersJapanese ? "資料.txt" : "Äæù┐.txt"
        case "cp437-valid":
            expression = "bytes.fromhex('4d 81 6c 6c 65 72 2e 74 78 74')"
            expected = prefersJapanese ? "M〕ler.txt" : "Müller.txt"
        default:
            expression = "bytes.fromhex('63 61 66 82 2e 74 78 74')"
            expected = "café.txt"
        }
        let (source, output) = try fixture("write_zip([\(expression)])")
        let original = try Data(contentsOf: source)
        try ArchiveListing.verify(source, prefersJapanese: prefersJapanese)
        let layout = try ArchiveExtractor.extract(
            source, into: output, rawName: "legacy", password: nil, prefersJapanese: prefersJapanese
        ) { _ in }
        #expect(layout == .entries)
        #expect(try Data(contentsOf: output.appending(path: expected)) == Data("legacy payload".utf8))
        #expect(try ArchiveBrowserZIP.list(source, prefersJapanese: prefersJapanese).map(\.path) == [expected])
        let selected = output.appending(path: "selected")
        try ArchiveBrowserZIP.extract(
            source, ordinal: 0, to: selected, password: nil, limit: 100, prefersJapanese: prefersJapanese)
        #expect(try Data(contentsOf: selected) == Data("legacy payload".utf8))
        #expect(try Data(contentsOf: source) == original)
    }

    @Test(arguments: [false, true])
    func invalidCP932TARNamesRemainRefused(_ prefersJapanese: Bool) throws {
        let (source, output) = try fixture(
            """
            header = bytearray(tarfile.TarInfo('placeholder').tobuf(format=tarfile.USTAR_FORMAT))
            header[:100] = b'bad\\x82.txt'.ljust(100, b'\\0')
            header[148:156] = b' ' * 8
            header[148:156] = ('%06o' % sum(header)).encode() + b'\\0 '
            source.write_bytes(header + bytes(1024))
            """, extensionName: "tar")
        #expect(throws: ArchiveError.unsupportedNameEncoding) {
            try ArchiveExtractor.extract(
                source, into: output, rawName: "legacy", password: nil, prefersJapanese: prefersJapanese
            ) { _ in }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        #expect(throws: ArchiveError.unsupportedNameEncoding) {
            try ArchiveListing.verify(source, prefersJapanese: prefersJapanese)
        }
        #expect(
            EngineError.wrapping(ArchiveError.unsupportedNameEncoding, path: source.path)
                == .invalidInput(.archiveNameEncodingUnsupported))
    }

    @Test func JapanesePreferenceIncludesSecondaryAndRegionalLanguages() {
        #expect(ArchivePathname.prefersJapanese(in: ["en-US", "ja-JP"]))
        #expect(ArchivePathname.prefersJapanese(in: ["fr", "ja-Latn"]))
        #expect(!ArchivePathname.prefersJapanese(in: ["en-JP", "de", "jv"]))
        #expect(!ArchivePathname.prefersJapanese(in: []))
    }

    @Test(arguments: ["../資料.txt", "/資料.txt", "資料/../outside.txt"])
    func decodedTraversalUsesTheExistingPathRefusal(_ path: String) throws {
        let (source, output) = try fixture("write_zip(['\(path)'.encode('cp932')])")
        #expect(throws: ArchiveError.unsafePath(path)) {
            try ArchiveExtractor.extract(source, into: output, rawName: "legacy", password: nil, prefersJapanese: true)
            { _ in }
        }
        #expect(throws: ZIPBrowserError.unsafeEntry) { try ArchiveBrowserZIP.list(source, prefersJapanese: true) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    }

    @Test(arguments: ["central", "local", "unicode"])
    func embeddedNULIsRefusedBeforeCStringTruncation(_ location: String) throws {
        let body: String
        switch location {
        case "central": body = "write_zip(['資料'.encode('cp932') + b'\\0escape'])"
        case "local":
            body = """
                write_zip(['資料.txt'.encode('cp932')])
                payload = bytearray(source.read_bytes())
                payload[30 + 4] = 0
                source.write_bytes(payload)
                """
        default:
            body = """
                raw_name = '資料.txt'.encode('cp932')
                unicode_name = '資料'.encode('utf-8') + b'\\0escape'
                field = b'\\x01' + struct.pack('<I', zlib.crc32(raw_name)) + unicode_name
                header = RawName(raw_name)
                header.extra = struct.pack('<HH', 0x7075, len(field)) + field
                with zipfile.ZipFile(source, 'w') as archive:
                    archive.writestr(header, b'legacy payload')
                """
        }
        let (source, output) = try fixture(body)
        #expect(throws: ArchiveError.unsafePath("ZIP filename contains NUL")) {
            try ArchiveExtractor.extract(source, into: output, rawName: "legacy", password: nil, prefersJapanese: true)
            { _ in }
        }
        #expect(throws: ZIPBrowserError.unsafeEntry) { try ArchiveBrowserZIP.list(source, prefersJapanese: true) }
        #expect(throws: ArchiveError.unsafePath("ZIP filename contains NUL")) {
            try ArchiveListing.verify(source, prefersJapanese: true)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    }

    @Test func cp932LinkTargetsUseTheSharedDecoder() throws {
        let (source, output) = try fixture(
            """
            with tarfile.open(source, 'w', format=tarfile.USTAR_FORMAT, encoding='cp932') as archive:
                header = tarfile.TarInfo('資料.txt')
                header.size = len(b'legacy payload')
                archive.addfile(header, io.BytesIO(b'legacy payload'))
                for name, kind in [('別名', tarfile.SYMTYPE), ('連結', tarfile.LNKTYPE)]:
                    header = tarfile.TarInfo(name)
                    header.type = kind
                    header.linkname = '資料.txt'
                    archive.addfile(header)
            """, extensionName: "tar")
        let layout = try ArchiveExtractor.extract(
            source, into: output, rawName: "legacy", password: nil, prefersJapanese: true
        ) { _ in }
        #expect(layout == .entries)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: output.appending(path: "別名").path) == "資料.txt")
        #expect(try Data(contentsOf: output.appending(path: "連結")) == Data("legacy payload".utf8))
        var original = stat()
        var linked = stat()
        #expect(stat(output.appending(path: "資料.txt").path, &original) == 0)
        #expect(stat(output.appending(path: "連結").path, &linked) == 0)
        #expect(original.st_ino == linked.st_ino)
    }

    @Test func decodedHardlinkTraversalIsRefused() throws {
        let (source, output) = try fixture(
            """
            with tarfile.open(source, 'w', format=tarfile.USTAR_FORMAT, encoding='cp932') as archive:
                header = tarfile.TarInfo('link')
                header.type = tarfile.LNKTYPE
                header.linkname = '../資料.txt'
                archive.addfile(header)
            """, extensionName: "tar")
        #expect(throws: ArchiveError.unsafePath("../資料.txt")) {
            try ArchiveExtractor.extract(source, into: output, rawName: "legacy", password: nil, prefersJapanese: true)
            { _ in }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    }

    @Test func decodedSymlinkTargetsKeepTheirRelativeSpelling() throws {
        let (source, output) = try fixture(
            """
            with tarfile.open(source, 'w', format=tarfile.USTAR_FORMAT, encoding='cp932') as archive:
                header = tarfile.TarInfo('link')
                header.type = tarfile.SYMTYPE
                header.linkname = '../資料.txt'
                archive.addfile(header)
            """, extensionName: "tar")
        let layout = try ArchiveExtractor.extract(
            source, into: output, rawName: "legacy", password: nil, prefersJapanese: true
        ) { _ in }
        #expect(layout == .entries)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: output.appending(path: "link").path)
                == "../資料.txt")
    }

    @Test(arguments: ["symlink", "hardlink"])
    func unreadableLinkTargetsAreRefused(_ kind: String) throws {
        let (source, output) = try fixture(
            """
            with tarfile.open(source, 'w', format=tarfile.USTAR_FORMAT, encoding='latin1') as archive:
                header = tarfile.TarInfo('link')
                header.type = tarfile.SYMTYPE if '\(kind)' == 'symlink' else tarfile.LNKTYPE
                header.linkname = 'caf\\x82.txt'
                archive.addfile(header)
            """, extensionName: "tar")
        #expect(throws: ArchiveError.unsupportedNameEncoding) {
            try ArchiveExtractor.extract(source, into: output, rawName: "legacy", password: nil, prefersJapanese: true)
            { _ in }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    }
}
