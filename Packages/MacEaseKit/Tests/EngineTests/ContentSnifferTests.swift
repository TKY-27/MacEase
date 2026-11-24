import Engine
import Foundation
import MenuCatalog
import Testing

@Suite struct ContentSnifferIdentifyTests {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "MacEaseSniffer-\(UUID().uuidString)")
        TestTemporaryFolders.register(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func write(_ name: String, bytes: [UInt8], in folder: URL) throws -> URL {
        let url = folder.appending(path: name)
        try Data(bytes).write(to: url)
        return url
    }

    @Test func identifiesEmptyTextSVGAndBinaryFiles() throws {
        let folder = try temporaryFolder()
        let empty = try write("empty.txt", bytes: [], in: folder)
        #expect(try ContentSniffer.identify(empty) == DetectedContent(family: .empty, displayName: "Empty file"))

        let plain = try write("notes.txt", bytes: Array("BM is a body metric\n".utf8), in: folder)
        #expect(try ContentSniffer.identify(plain) == DetectedContent(family: .text, displayName: "Text"))

        let utf16 = try write("utf16.txt", bytes: [0xFF, 0xFE, 0x41, 0x00], in: folder)
        #expect(try ContentSniffer.identify(utf16) == DetectedContent(family: .text, displayName: "Text"))

        let htmlWithInlineSVG = try write(
            "page.html", bytes: Array("<!DOCTYPE html><html><body><svg></svg></body></html>".utf8), in: folder)
        #expect(try ContentSniffer.identify(htmlWithInlineSVG) == DetectedContent(family: .text, displayName: "Text"))

        let svg = try write(
            "icon.svg", bytes: Array("<?xml version=\"1.0\"?>\n<!-- note -->\n<svg viewBox=\"0 0 10 10\"/>".utf8),
            in: folder)
        #expect(try ContentSniffer.identify(svg) == DetectedContent(family: .svg, displayName: "SVG"))

        let rawBinary = try write("blob.bin", bytes: [0x01, 0x02, 0x00, 0x04], in: folder)
        #expect(try ContentSniffer.identify(rawBinary) == DetectedContent(family: .binary, displayName: "Binary file"))
    }

    @Test func signaturesInsideTextDoNotMakeItBinary() throws {
        let folder = try temporaryFolder()
        let source = try write(
            "Signature.swift", bytes: Array("// Checks headers.\nlet signature = \"%PDF-1.7\"\n".utf8), in: folder)
        #expect(try ContentSniffer.identify(source) == DetectedContent(family: .text, displayName: "Text"))

        let pdf = try write("doc.pdf", bytes: Array("%PDF-1.7\n%\u{00E2}\n1 0 obj\n".utf8), in: folder)
        #expect(try ContentSniffer.identify(pdf).family == .pdf)
    }

    @Test func textDecisionFollowsDecodableEncodings() throws {
        let folder = try temporaryFolder()
        let littleEndian = try write(
            "le.txt", bytes: Array("Hello, world.\n".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }), in: folder)
        #expect(try ContentSniffer.identify(littleEndian) == DetectedContent(family: .text, displayName: "Text"))

        let bigEndian = try write(
            "be.txt", bytes: Array("日本語のテキスト。\n".utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }), in: folder)
        #expect(try ContentSniffer.identify(bigEndian) == DetectedContent(family: .text, displayName: "Text"))

        let shortLittleEndian = try write("ab.txt", bytes: [0x41, 0x00, 0x42, 0x00], in: folder)
        #expect(try ContentSniffer.identify(shortLittleEndian) == DetectedContent(family: .text, displayName: "Text"))

        let controls = try write("controls.txt", bytes: [0x01, 0x02, 0x03, 0x04], in: folder)
        #expect(try ContentSniffer.identify(controls) == DetectedContent(family: .binary, displayName: "Binary file"))

        let shiftJIS = try write("sjis.txt", bytes: [0x93, 0xFA, 0x96, 0x7B, 0x8C, 0xEA, 0x0A], in: folder)
        #expect(try ContentSniffer.identify(shiftJIS) == DetectedContent(family: .text, displayName: "Text"))

        let tabsAndEscapes = try write(
            "iso2022.txt", bytes: [0x09, 0x1B, 0x24, 0x42, 0x46, 0x7C, 0x1B, 0x28, 0x42, 0x0D, 0x0A, 0x0C], in: folder)
        #expect(try ContentSniffer.identify(tabsAndEscapes) == DetectedContent(family: .text, displayName: "Text"))

        var random = SystemRandomNumberGenerator()
        let noise = try write(
            "noise.bin", bytes: (0..<4096).map { _ in UInt8.random(in: 0...255, using: &random) }, in: folder)
        #expect(try ContentSniffer.identify(noise).family == .binary)
    }

    @Test func identifiesAllScriptsAcrossSupportedEncodingsAndRejectsUndecodableBinary() throws {
        let folder = try temporaryFolder()
        let utf16LE: (String) -> [UInt8] = { text in
            text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        }
        let utf16BE: (String) -> [UInt8] = { text in
            text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        }
        let utf32LE: (String) -> [UInt8] = { text in
            text.unicodeScalars.flatMap { scalar in
                let value = scalar.value
                return [
                    UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
                    UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF),
                ]
            }
        }
        let utf32BE: (String) -> [UInt8] = { text in
            text.unicodeScalars.flatMap { scalar in
                let value = scalar.value
                return [
                    UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                    UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
                ]
            }
        }

        let scripts = [
            ("cyrillic", "Привет, мир!\nСтрока два.\n"),
            ("cyrillic-bare", "Привет"),
            ("arabic", "مرحبا بالعالم\nسطر ثاني\n"),
            ("emoji", "Hello 👋🌍🎉😀\n"),
            ("emoji-only", "👋🌍🎉😀"),
            ("hebrew", "שלום עולם\n"),
            ("greek", "Γειά σου κόσμε\n"),
            ("devanagari", "नमस्ते दुनिया\n"),
            ("devanagari-bare", "नमस्ते"),
            ("thai", "สวัสดีชาวโลก\n"),
            ("korean", "한국어 테스트\n"),
            ("japanese", "日本語のテキスト。\n"),
            ("japanese-bare", "日本語のテキスト"),
            ("mixed-four", "Hello Привет مرحبا दुनिया"),
            ("mixed-dense", "abcéЖم字éЖم字éЖم字éЖم字éЖم字"),
        ]
        for (label, text) in scripts {
            let variants: [(String, [UInt8])] = [
                ("\(label)-utf8.txt", Array(text.utf8)),
                ("\(label)-utf8-bom.txt", [0xEF, 0xBB, 0xBF] + Array(text.utf8)),
                ("\(label)-utf16le.txt", utf16LE(text)),
                ("\(label)-utf16be.txt", utf16BE(text)),
                ("\(label)-utf16le-bom.txt", [0xFF, 0xFE] + utf16LE(text)),
                ("\(label)-utf16be-bom.txt", [0xFE, 0xFF] + utf16BE(text)),
                ("\(label)-utf32le.txt", utf32LE(text)),
                ("\(label)-utf32be.txt", utf32BE(text)),
                ("\(label)-utf32le-bom.txt", [0xFF, 0xFE, 0x00, 0x00] + utf32LE(text)),
                ("\(label)-utf32be-bom.txt", [0x00, 0x00, 0xFE, 0xFF] + utf32BE(text)),
            ]
            for (name, bytes) in variants {
                let file = try write(name, bytes: bytes, in: folder)
                #expect(
                    try ContentSniffer.identify(file) == DetectedContent(family: .text, displayName: "Text"),
                    "\(name)")
                #expect(try TextEncoding.detectedString(from: Data(bytes)) == text, "\(name)")
            }
        }

        let eucJP = try #require("日本語のテキスト\n".data(using: .japaneseEUC))
        let iso2022 = try #require("日本語のテキスト\n".data(using: .iso2022JP))
        let latin1 = try #require("Café résumé naïve\n".data(using: .isoLatin1))
        let win1252 = try #require("Price: €10 — “ok”\n".data(using: .windowsCP1252))
        let shiftJIS = try #require("日本語のテキストです。\n".data(using: .shiftJIS))
        for (name, data, expected) in [
            ("eucjp.txt", eucJP, "日本語のテキスト\n"),
            ("iso2022.txt", iso2022, "日本語のテキスト\n"),
            ("latin1.txt", latin1, "Café résumé naïve\n"),
            ("cp1252.txt", win1252, "Price: €10 — “ok”\n"),
            ("sjis.txt", shiftJIS, "日本語のテキストです。\n"),
        ] {
            let file = try write(name, bytes: [UInt8](data), in: folder)
            #expect(try ContentSniffer.identify(file) == DetectedContent(family: .text, displayName: "Text"), "\(name)")
            #expect(try TextEncoding.detectedString(from: data) == expected, "\(name)")
        }

        // Truncated mid-surrogate UTF-16LE emoji stays text.
        let longEmoji = String(repeating: "👋", count: 1500)
        let longEmojiFile = try write("long-emoji.txt", bytes: utf16LE(longEmoji), in: folder)
        #expect(try ContentSniffer.identify(longEmojiFile) == DetectedContent(family: .text, displayName: "Text"))

        // Binary lookalikes fail both sniffing and auto-detection.
        let binaries: [(String, [UInt8])] = [
            ("ones64.bin", [UInt8](repeating: 0x01, count: 64)),
            ("zeros64.bin", [UInt8](repeating: 0x00, count: 64)),
            ("controls-repeat.bin", Array(repeating: [UInt8(0x02), 0x03, 0x04, 0x05], count: 16).flatMap { $0 }),
            ("utf16-controls.bin", [0x01, 0x00, 0x02, 0x00, 0x03, 0x00]),
            ("utf16-pua-bom.bin", [0xFE, 0xFF, 0xE0, 0x00, 0xE0, 0x01]),
            ("utf16-unassigned.bin", [0xFF, 0x03, 0xFE, 0x03, 0x78, 0x03, 0x79, 0x03]),
            ("utf16-mixed-nul-ctrl.bin", [0x00, 0x01, 0x02, 0x00, 0x03, 0x00, 0x00, 0x04]),
            ("c1.bin", [0x81, 0x8D, 0x8F, 0x90, 0x9D]),
            ("surrogate.bin", [0x00, 0xD8, 0x41, 0x00]),
        ]
        for (name, bytes) in binaries {
            let file = try write(name, bytes: bytes, in: folder)
            #expect(
                try ContentSniffer.identify(file) == DetectedContent(family: .binary, displayName: "Binary file"),
                "\(name)")
            #expect(throws: EngineError.invalidInput(.textEncodingUndetected)) {
                _ = try TextEncoding.detectedString(from: Data(bytes))
            }
        }
    }

    @Test func identifiesMachOAndUniversalFatHeadersWithoutConfusingJavaClass() throws {
        let folder = try temporaryFolder()
        let machOHeaders: [[UInt8]] = [
            [0xFE, 0xED, 0xFA, 0xCE, 0x00, 0x00, 0x00, 0x07],
            [0xCE, 0xFA, 0xED, 0xFE, 0x07, 0x00, 0x00, 0x00],
            [0xFE, 0xED, 0xFA, 0xCF, 0x01, 0x00, 0x00, 0x0C],
            [0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01],
        ]
        for (index, header) in machOHeaders.enumerated() {
            let file = try write("macho-\(index)", bytes: header, in: folder)
            #expect(
                try ContentSniffer.identify(file)
                    == DetectedContent(family: .executable, displayName: "Mach-O executable"))
        }

        let fatHeaders: [[UInt8]] = [
            [0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x02],
            [0xCA, 0xFE, 0xBA, 0xBF, 0x00, 0x00, 0x00, 0x02],
            [0xBE, 0xBA, 0xFE, 0xCA, 0x02, 0x00, 0x00, 0x00],
            [0xBF, 0xBA, 0xFE, 0xCA, 0x02, 0x00, 0x00, 0x00],
        ]
        for (index, header) in fatHeaders.enumerated() {
            let file = try write("fat-\(index)", bytes: header, in: folder)
            #expect(
                try ContentSniffer.identify(file)
                    == DetectedContent(family: .executable, displayName: "Mach-O universal binary"))
        }

        let javaClass = try write("Main.class", bytes: [0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x41], in: folder)
        #expect(
            try ContentSniffer.identify(javaClass) == DetectedContent(family: .binary, displayName: "Java class file"))

        let elf = try write("tool", bytes: [0x7F, 0x45, 0x4C, 0x46, 0x02, 0x01], in: folder)
        #expect(try ContentSniffer.identify(elf) == DetectedContent(family: .executable, displayName: "ELF executable"))
    }

    @Test func identifiesImagesMediaDocumentsFontsArchivesAndPlists() throws {
        let folder = try temporaryFolder()
        let cases: [(String, [UInt8], ContentFamily, String)] = [
            ("a.png", [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], .image, "PNG"),
            ("a.jpg", [0xFF, 0xD8, 0xFF, 0xE0], .image, "JPEG"),
            ("a.gif", Array("GIF89a".utf8), .image, "GIF"),
            ("a.webp", Array("RIFF1234WEBP".utf8), .image, "WebP"),
            ("a.pdf", Array("%PDF-1.7\n".utf8), .pdf, "PDF"),
            ("a.plist", Array("bplist00".utf8) + [0x00], .binaryPropertyList, "Binary Property List"),
            ("a.mkv", [0x1A, 0x45, 0xDF, 0xA3, 0x9F], .video, "Matroska video"),
            ("a.webm", [0x1A, 0x45, 0xDF, 0xA3] + Array("webm".utf8), .video, "WebM"),
            ("a.avi", Array("RIFF1234AVI ".utf8), .video, "AVI"),
            ("a.flv", [0x46, 0x4C, 0x56, 0x01, 0x05], .video, "Flash Video"),
            (
                "a.mp4", [0x00, 0x00, 0x00, 0x14] + Array("ftypisom".utf8) + [0, 0, 0, 0] + Array("isom".utf8), .video,
                "MP4"
            ),
            (
                "a.m4a", [0x00, 0x00, 0x00, 0x14] + Array("ftypM4A ".utf8) + [0, 0, 0, 0] + Array("M4A ".utf8), .audio,
                "MPEG-4 audio"
            ),
            ("a.mp3", Array("ID3".utf8) + [0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10], .audio, "MP3"),
            ("a.flac", Array("fLaC".utf8) + [0x00, 0x00, 0x00, 0x22], .audio, "FLAC"),
            ("a.ogg", Array("OggS".utf8) + [0x00, 0x02], .audio, "Ogg audio"),
            ("a.wav", Array("RIFF1234WAVE".utf8), .audio, "WAV"),
            (
                "a.ttf", [0x00, 0x01, 0x00, 0x00, 0x00, 0x0A, 0x00, 0x80, 0x00, 0x03, 0x00, 0x20], .font,
                "TrueType font"
            ),
            ("a.otf", Array("OTTO".utf8) + [0x00, 0x09, 0x00, 0x80, 0x00, 0x03, 0x00, 0x10], .font, "OpenType font"),
            ("a.ttc", Array("ttcf".utf8) + [0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02], .font, "Font collection"),
            ("a.woff", Array("wOFF".utf8) + [UInt8](repeating: 0, count: 40), .font, "WOFF font"),
            ("a.woff2", Array("wOF2".utf8) + [UInt8](repeating: 0, count: 44), .font, "WOFF2 font"),
            ("a.zip", [0x50, 0x4B, 0x03, 0x04, 0x14, 0x00], .archive, "ZIP archive"),
            ("a.gz", [0x1F, 0x8B, 0x08, 0x00], .archive, "Gzip archive"),
        ]
        for (name, bytes, family, displayName) in cases {
            let file = try write(name, bytes: bytes, in: folder)
            #expect(try ContentSniffer.identify(file) == DetectedContent(family: family, displayName: displayName))
        }
    }

    @Test func rejectsDirectoriesInIdentify() throws {
        let folder = try temporaryFolder()
        #expect(throws: EngineError.invalidInput(.unsupportedFileType)) {
            try ContentSniffer.identify(folder)
        }
    }

    @Test func detectsConcreteEncodingsIncludingGB18030BOM() throws {
        let folder = try temporaryFolder()
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let gbBody = try #require("简体中文 😀\n".data(using: gb18030))
        let gbWithBOM = Data([0x84, 0x31, 0x95, 0x33]) + gbBody

        let gbFile = try write("zh-bom.txt", bytes: [UInt8](gbWithBOM), in: folder)
        #expect(try ContentSniffer.identify(gbFile) == DetectedContent(family: .text, displayName: "Text"))
        let gbDetected = try TextEncoding.detect(from: gbWithBOM)
        #expect(gbDetected == DetectedText(text: "简体中文 😀\n", encoding: .gb18030))

        let gbEmoji = Data([0x84, 0x31, 0x95, 0x33]) + (try #require("简体😀".data(using: gb18030)))
        #expect(
            try TextEncoding.detect(from: gbEmoji.dropLast(1), truncated: true)
                == DetectedText(text: "简体", encoding: .gb18030))
        #expect(throws: EngineError.invalidInput(.textEncodingUndetected)) {
            _ = try TextEncoding.detect(from: gbEmoji.dropLast(1), truncated: false)
        }

        let gbBinary = try write("fake-gb.bin", bytes: [0x84, 0x31, 0x95, 0x33, 0x00, 0x01], in: folder)
        #expect(try ContentSniffer.identify(gbBinary) == DetectedContent(family: .binary, displayName: "Binary file"))

        let samples: [(Data, DetectedTextEncoding, String)] = [
            (Data("Hello UTF-8\n".utf8), .utf8, "Hello UTF-8\n"),
            (Data([0xEF, 0xBB, 0xBF]) + Data("Hello\n".utf8), .utf8, "Hello\n"),
            (Data([0xFF, 0xFE, 0x41, 0x00]), .utf16LE, "A"),
            (Data([0xFE, 0xFF, 0x00, 0x41]), .utf16BE, "A"),
            (Data([0xFF, 0xFE, 0x00, 0x00, 0x41, 0x00, 0x00, 0x00]), .utf32LE, "A"),
            (Data([0x00, 0x00, 0xFE, 0xFF, 0x00, 0x00, 0x00, 0x41]), .utf32BE, "A"),
            (try #require("日本語です\n".data(using: .shiftJIS)), .shiftJIS, "日本語です\n"),
            (try #require("日本語のテキスト\n".data(using: .japaneseEUC)), .eucJP, "日本語のテキスト\n"),
            (try #require("日本語\n".data(using: .iso2022JP)), .iso2022JP, "日本語\n"),
            (try #require("Price: €10\n".data(using: .windowsCP1252)), .windows1252, "Price: €10\n"),
        ]
        for (bytes, expectedEncoding, expectedText) in samples {
            #expect(
                try TextEncoding.detect(from: bytes) == DetectedText(text: expectedText, encoding: expectedEncoding))
        }
    }
}
