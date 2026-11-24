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
}
