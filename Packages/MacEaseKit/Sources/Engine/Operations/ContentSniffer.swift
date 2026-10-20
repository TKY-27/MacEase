import Foundation
import MenuCatalog

enum ContentSniffer {
    private static let headerLength = 4096

    static func matches(_ url: URL, kind: FileKind) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        let isFolder = values.isDirectory == true && values.isPackage != true
        switch kind {
        case .folder: return isFolder
        case .any: return values.isDirectory != true
        default: break
        }
        guard values.isDirectory != true else { return false }
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        let header = [UInt8](try reader.read(upToCount: headerLength) ?? Data())
        switch kind {
        case .image: return isImage(header)
        case .video: return isVideo(header)
        case .audio: return isAudio(header)
        case .pdf: return isPDF(header)
        case .text: return isText(header)
        case .archive: return isArchive(header)
        case .jar: return isZip(header)
        case .folder, .any: return false
        }
    }

    private static func starts(_ header: [UInt8], with signature: [UInt8], at offset: Int = 0) -> Bool {
        header.count >= offset + signature.count && Array(header[offset..<offset + signature.count]) == signature
    }

    private static func ascii(_ text: String) -> [UInt8] { Array(text.utf8) }

    private static func isoBrand(_ header: [UInt8]) -> String? {
        guard starts(header, with: ascii("ftyp"), at: 4), header.count >= 12 else { return nil }
        return String(decoding: header[8..<12], as: UTF8.self)
    }

    private static func isImage(_ header: [UInt8]) -> Bool {
        let signatures: [[UInt8]] = [
            [0xFF, 0xD8, 0xFF], [0x89, 0x50, 0x4E, 0x47], ascii("GIF8"), ascii("BM"), [0x49, 0x49, 0x2A, 0x00],
            [0x4D, 0x4D, 0x00, 0x2A], [0x49, 0x49, 0x55, 0x00], [0x49, 0x49, 0x52, 0x4F], [0x49, 0x49, 0x52, 0x53],
            [0x4D, 0x4D, 0x4F, 0x52], [0xFF, 0x0A], [0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20],
            [0x00, 0x00, 0x01, 0x00], ascii("icns"), ascii("FUJIFILMCCD-RAW"),
        ]
        if signatures.contains(where: { starts(header, with: $0) }) { return true }
        if starts(header, with: ascii("RIFF")), starts(header, with: ascii("WEBP"), at: 8) { return true }
        if let brand = isoBrand(header) {
            return ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1", "avif", "avis", "crx "]
                .contains(brand)
        }
        return isSVG(header)
    }

    private static func isSVG(_ header: [UInt8]) -> Bool {
        let text = String(decoding: header, as: UTF8.self).lowercased()
        return text.contains("<svg")
    }

    private static func isVideo(_ header: [UInt8]) -> Bool {
        if starts(header, with: [0x1A, 0x45, 0xDF, 0xA3]) || starts(header, with: ascii("FLV")) { return true }
        if starts(header, with: ascii("RIFF")), starts(header, with: ascii("AVI "), at: 8) { return true }
        if let brand = isoBrand(header) {
            return !["M4A ", "M4B ", "M4P ", "heic", "heix", "mif1", "msf1", "avif", "avis", "crx "].contains(brand)
        }
        return ["moov", "mdat", "wide", "free", "skip"].contains { starts(header, with: ascii($0), at: 4) }
    }

    private static func isAudio(_ header: [UInt8]) -> Bool {
        let signatures = ["ID3", "fLaC", "OggS", "caff"].map(ascii)
        if signatures.contains(where: { starts(header, with: $0) }) { return true }
        // WMA passes, then fails naming its codec.
        if starts(header, with: AudioInput.asfSignature) { return true }
        if starts(header, with: ascii("RIFF")), starts(header, with: ascii("WAVE"), at: 8) { return true }
        if starts(header, with: ascii("FORM")), starts(header, with: ascii("AIF"), at: 8) { return true }
        if let brand = isoBrand(header) { return ["M4A ", "M4B ", "mp42", "isom", "dash"].contains(brand) }
        // MPEG audio frame sync or ADTS.
        return header.count >= 2 && header[0] == 0xFF && header[1] & 0xE0 == 0xE0
    }

    private static func isPDF(_ header: [UInt8]) -> Bool {
        let window = header.prefix(1024)
        let marker = ascii("%PDF-")
        return window.indices.contains { index in
            index + marker.count <= window.endIndex && Array(window[index..<index + marker.count]) == marker
        }
    }

    private static func isText(_ header: [UInt8]) -> Bool {
        if starts(header, with: [0xFF, 0xFE]) || starts(header, with: [0xFE, 0xFF]) { return true }
        return !header.contains(0)
    }

    private static func isZip(_ header: [UInt8]) -> Bool {
        starts(header, with: [0x50, 0x4B, 0x03, 0x04]) || starts(header, with: [0x50, 0x4B, 0x05, 0x06])
    }

    private static func isArchive(_ header: [UInt8]) -> Bool {
        let signatures: [[UInt8]] = [
            [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C], [0x1F, 0x8B], ascii("BZh"), [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00],
            ascii("Rar!"),
        ]
        return isZip(header) || signatures.contains { starts(header, with: $0) }
            || starts(header, with: ascii("ustar"), at: 257)
    }
}
