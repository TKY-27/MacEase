import Foundation
import ImageIO
import MenuCatalog

public enum ContentFamily: Equatable, Hashable, Sendable {
    case empty
    case image
    case svg
    case video
    case audio
    case pdf
    case font
    case archive
    case binaryPropertyList
    case executable
    case text
    case binary
}

public struct DetectedContent: Equatable, Sendable {
    public let family: ContentFamily
    public let displayName: String

    public init(family: ContentFamily, displayName: String) {
        self.family = family
        self.displayName = displayName
    }
}

public enum ContentSniffer {
    private static let headerLength = 4096
    private static let maximumFatArchitectures: UInt32 = 32
    private static let minimumJavaClassMajorVersion: UInt32 = 45
    private static let bmpHeaderSizes: Set<UInt32> = [12, 40, 52, 56, 64, 108, 124]
    private static let asfVideoStreamGUID: [UInt8] = [
        0xC0, 0xEF, 0x19, 0xBC, 0x4D, 0x5B, 0xCF, 0x11, 0xA8, 0xFD, 0x00, 0x80, 0x5F, 0x5C, 0x44, 0x2B,
    ]

    public static func identify(_ url: URL) throws -> DetectedContent {
        let values = try inputValues(url)
        guard values.isDirectory != true else { throw EngineError.invalidInput(.unsupportedFileType) }
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        let raw = [UInt8](try reader.read(upToCount: headerLength + 1) ?? Data())
        let truncated = raw.count > headerLength
        let header = truncated ? Array(raw.prefix(headerLength)) : raw
        let detected = identify(header: header, truncated: truncated)
        guard detected.family == .binary,
            let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            (CGImageSourceGetType(source) as String?) == "com.truevision.tga-image"
        else { return detected }
        return DetectedContent(family: .image, displayName: "TGA")
    }

    /// Unlike `identify(_:)`, never reports TGA.
    public static func identify(header: [UInt8]) -> DetectedContent {
        identify(header: header, truncated: header.count >= headerLength)
    }

    private static func identify(header: [UInt8], truncated: Bool) -> DetectedContent {
        if header.isEmpty { return DetectedContent(family: .empty, displayName: "Empty file") }
        if let executable = identifyExecutable(header) { return executable }
        if starts(header, with: ascii("bplist00")) {
            return DetectedContent(family: .binaryPropertyList, displayName: "Binary Property List")
        }
        // Text may quote it; require offset zero.
        if starts(header, with: ascii("%PDF-")) { return DetectedContent(family: .pdf, displayName: "PDF") }
        if let font = identifyFont(header) { return font }
        if let iso = identifyISOBaseMedia(header) { return iso }
        if let image = identifyImage(header) { return image }
        if let video = identifyVideo(header) { return video }
        if let audio = identifyAudio(header) { return audio }
        if let archive = identifyArchive(header) { return archive }
        if let decoded = TextEncoding.plausibleBOMText(from: header, truncated: truncated) {
            return isSVGRoot(decoded)
                ? DetectedContent(family: .svg, displayName: "SVG")
                : DetectedContent(family: .text, displayName: "Text")
        }
        if let mpegAudio = identifyMPEGAudio(header) { return mpegAudio }
        if let decoded = TextEncoding.plausibleDecodedText(from: header, truncated: truncated) {
            return isSVGRoot(decoded)
                ? DetectedContent(family: .svg, displayName: "SVG")
                : DetectedContent(family: .text, displayName: "Text")
        }
        return DetectedContent(family: .binary, displayName: "Binary file")
    }

    static func inputValues(_ url: URL) throws -> URLResourceValues {
        let values = try url.resolvingSymlinksInPath().resourceValues(
            forKeys: [.isRegularFileKey, .isDirectoryKey, .isPackageKey])
        guard values.isRegularFile == true || values.isDirectory == true else {
            throw EngineError.invalidInput(.unsupportedFileType)
        }
        return values
    }

    static func matches(_ url: URL, kind: FileKind) throws -> Bool {
        let values = try inputValues(url)
        let isFolder = values.isDirectory == true && values.isPackage != true
        switch kind {
        case .folder: return isFolder
        case .any: return values.isDirectory != true
        case .document where url.pathExtension.lowercased() == "rtfd": return values.isDirectory == true
        default: break
        }
        guard values.isDirectory != true else { return false }
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        let header = [UInt8](try reader.read(upToCount: headerLength) ?? Data())
        switch kind {
        case .image:
            if isImage(header) { return true }
            guard
                let source = CGImageSourceCreateWithURL(
                    url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                let identifier = CGImageSourceGetType(source) as String?
            else { return false }
            return ["com.adobe.photoshop-image", "com.truevision.tga-image"].contains(identifier)
        case .video: return isVideo(header)
        case .audio: return isAudio(header)
        case .pdf: return isPDF(header)
        case .document:
            switch url.pathExtension.lowercased() {
            case "docx", "odt": return isZip(header)
            case "rtf": return starts(header, with: ascii("{\\rtf"))
            default: return false
            }
        case .plist: return starts(header, with: ascii("bplist00")) || isText(header)
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
            || isFallbackVideo(header)
    }

    private static func isAudio(_ header: [UInt8]) -> Bool {
        let signatures = ["ID3", "fLaC", "OggS", "caff"].map(ascii)
        if signatures.contains(where: { starts(header, with: $0) }) { return true }
        // WMA passes, then fails naming its codec.
        if starts(header, with: AudioInput.asfSignature) { return true }
        if ["RIFF", "RF64", "BW64"].contains(where: { starts(header, with: ascii($0)) }),
            starts(header, with: ascii("WAVE"), at: 8)
        {
            return true
        }
        if starts(header, with: ascii("FORM")), starts(header, with: ascii("AIF"), at: 8) { return true }
        if let brand = isoBrand(header) { return ["M4A ", "M4B ", "mp42", "isom", "dash"].contains(brand) }
        // MPEG audio frame sync or ADTS.
        return (header.count >= 2 && header[0] == 0xFF && header[1] & 0xE0 == 0xE0) || isFallbackAudio(header)
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
            || isTar(header)
    }

    private static func isTar(_ header: [UInt8]) -> Bool {
        let blockSize = 512
        let checksumRange = 148..<156
        let space: UInt8 = 0x20
        guard header.count >= blockSize, header[0] != 0 else { return false }
        let digits = header[checksumRange].drop(while: { $0 == 0 || $0 == space })
            .prefix(while: { (0x30...0x37).contains($0) })
        guard !digits.isEmpty,
            header[digits.endIndex..<checksumRange.upperBound].allSatisfy({ $0 == 0 || $0 == space })
        else { return false }
        let stored = digits.reduce(0) { $0 * 8 + Int($1 - 0x30) }
        let actual =
            header[..<checksumRange.lowerBound].reduce(0) { $0 + Int($1) }
            + checksumRange.count * Int(space)
            + header[checksumRange.upperBound..<blockSize].reduce(0) { $0 + Int($1) }
        return stored == actual
    }

    private static func identifyExecutable(_ header: [UInt8]) -> DetectedContent? {
        let machOHeaders: [[UInt8]] = [
            [0xFE, 0xED, 0xFA, 0xCE], [0xCE, 0xFA, 0xED, 0xFE],
            [0xFE, 0xED, 0xFA, 0xCF], [0xCF, 0xFA, 0xED, 0xFE],
        ]
        if machOHeaders.contains(where: { starts(header, with: $0) }) {
            return DetectedContent(family: .executable, displayName: "Mach-O executable")
        }
        if header.count >= 8 {
            if starts(header, with: [0xCA, 0xFE, 0xBA, 0xBE]) {
                let count = uint32BE(header, at: 4)
                if (1...maximumFatArchitectures).contains(count) {
                    return DetectedContent(family: .executable, displayName: "Mach-O universal binary")
                }
                if count >= minimumJavaClassMajorVersion {
                    return DetectedContent(family: .binary, displayName: "Java class file")
                }
            }
            if starts(header, with: [0xCA, 0xFE, 0xBA, 0xBF]),
                (1...maximumFatArchitectures).contains(uint32BE(header, at: 4))
            {
                return DetectedContent(family: .executable, displayName: "Mach-O universal binary")
            }
            if (starts(header, with: [0xBE, 0xBA, 0xFE, 0xCA]) || starts(header, with: [0xBF, 0xBA, 0xFE, 0xCA])),
                (1...maximumFatArchitectures).contains(uint32LE(header, at: 4))
            {
                return DetectedContent(family: .executable, displayName: "Mach-O universal binary")
            }
        }
        if starts(header, with: [0x7F, 0x45, 0x4C, 0x46]) {
            return DetectedContent(family: .executable, displayName: "ELF executable")
        }
        return nil
    }

    private static func identifyFont(_ header: [UInt8]) -> DetectedContent? {
        if starts(header, with: [0x00, 0x01, 0x00, 0x00]), header.count >= 12, uint16BE(header, at: 4) > 0 {
            return DetectedContent(family: .font, displayName: "TrueType font")
        }
        if starts(header, with: ascii("OTTO")), header.count >= 12, uint16BE(header, at: 4) > 0, header.contains(0) {
            return DetectedContent(family: .font, displayName: "OpenType font")
        }
        if starts(header, with: ascii("ttcf")),
            starts(header, with: [0x00, 0x01, 0x00, 0x00], at: 4)
                || starts(header, with: [0x00, 0x02, 0x00, 0x00], at: 4)
        {
            return DetectedContent(family: .font, displayName: "Font collection")
        }
        if starts(header, with: ascii("wOFF")), header.count >= 44 {
            return DetectedContent(family: .font, displayName: "WOFF font")
        }
        if starts(header, with: ascii("wOF2")), header.count >= 48 {
            return DetectedContent(family: .font, displayName: "WOFF2 font")
        }
        return nil
    }

    private static func identifyISOBaseMedia(_ header: [UInt8]) -> DetectedContent? {
        guard let brand = isoBrand(header) else { return nil }
        if ["avif", "avis"].contains(brand) { return DetectedContent(family: .image, displayName: "AVIF") }
        if ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1"].contains(brand) {
            return DetectedContent(family: .image, displayName: "HEIF")
        }
        if brand == "crx " { return DetectedContent(family: .image, displayName: "Canon RAW") }
        if ["M4A ", "M4B ", "M4P "].contains(brand) {
            return DetectedContent(family: .audio, displayName: "MPEG-4 audio")
        }
        if brand == "qt  " { return DetectedContent(family: .video, displayName: "QuickTime movie") }
        if brand == "M4V " { return DetectedContent(family: .video, displayName: "M4V video") }
        if brand.hasPrefix("3gp") || brand.hasPrefix("3g2") {
            return DetectedContent(family: .video, displayName: "3GP video")
        }
        let compatible = isoCompatibleBrands(header)
        let videoBrands: Set<String> = ["avc1", "hev1", "hvc1", "mp4v", "M4V ", "qt  "]
        if compatible.contains("M4A "), compatible.isDisjoint(with: videoBrands) {
            return DetectedContent(family: .audio, displayName: "MPEG-4 audio")
        }
        return DetectedContent(family: .video, displayName: "MP4")
    }

    private static func isoCompatibleBrands(_ header: [UInt8]) -> Set<String> {
        guard header.count >= 16 else { return [] }
        let boxSize = min(Int(uint32BE(header, at: 0)), header.count)
        guard boxSize >= 20 else { return [] }
        var brands: Set<String> = []
        var offset = 16
        while offset + 4 <= boxSize {
            brands.insert(String(decoding: header[offset..<(offset + 4)], as: UTF8.self))
            offset += 4
        }
        return brands
    }

    private static func identifyImage(_ header: [UInt8]) -> DetectedContent? {
        if starts(header, with: [0x89, 0x50, 0x4E, 0x47]) {
            return DetectedContent(family: .image, displayName: "PNG")
        }
        if starts(header, with: [0xFF, 0xD8, 0xFF]) { return DetectedContent(family: .image, displayName: "JPEG") }
        if starts(header, with: ascii("GIF87a")) || starts(header, with: ascii("GIF89a")) {
            return DetectedContent(family: .image, displayName: "GIF")
        }
        if starts(header, with: ascii("RIFF")), starts(header, with: ascii("WEBP"), at: 8) {
            return DetectedContent(family: .image, displayName: "WebP")
        }
        if starts(header, with: ascii("BM")), header.count >= 18,
            header[6..<10].allSatisfy({ $0 == 0 }), bmpHeaderSizes.contains(uint32LE(header, at: 14))
        {
            return DetectedContent(family: .image, displayName: "BMP")
        }
        if starts(header, with: [0x49, 0x49, 0x2A, 0x00]) || starts(header, with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return DetectedContent(family: .image, displayName: "TIFF")
        }
        let rawHeaders: [[UInt8]] = [
            [0x49, 0x49, 0x55, 0x00], [0x49, 0x49, 0x52, 0x4F],
            [0x49, 0x49, 0x52, 0x53], [0x4D, 0x4D, 0x4F, 0x52], ascii("FUJIFILMCCD-RAW"),
        ]
        if rawHeaders.contains(where: { starts(header, with: $0) }) {
            return DetectedContent(family: .image, displayName: "RAW image")
        }
        if starts(header, with: [0xFF, 0x0A]) || starts(header, with: [0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20])
        {
            return DetectedContent(family: .image, displayName: "JPEG XL")
        }
        if starts(header, with: [0x00, 0x00, 0x01, 0x00]) {
            return DetectedContent(family: .image, displayName: "ICO")
        }
        if starts(header, with: ascii("icns")), header.count >= 8, header.contains(0) {
            return DetectedContent(family: .image, displayName: "ICNS")
        }
        if starts(header, with: ascii("8BPS")),
            starts(header, with: [0x00, 0x01], at: 4) || starts(header, with: [0x00, 0x02], at: 4)
        {
            return DetectedContent(family: .image, displayName: "Photoshop image")
        }
        return nil
    }

    private static func identifyVideo(_ header: [UInt8]) -> DetectedContent? {
        if starts(header, with: [0x1A, 0x45, 0xDF, 0xA3]) {
            return containsBytes(header, sequence: ascii("webm"))
                ? DetectedContent(family: .video, displayName: "WebM")
                : DetectedContent(family: .video, displayName: "Matroska video")
        }
        if starts(header, with: [0x46, 0x4C, 0x56, 0x01]) {
            return DetectedContent(family: .video, displayName: "Flash Video")
        }
        if starts(header, with: ascii("RIFF")), starts(header, with: ascii("AVI "), at: 8) {
            return DetectedContent(family: .video, displayName: "AVI")
        }
        if header.contains(0),
            ["moov", "mdat", "wide", "free", "skip"].contains(where: {
                starts(header, with: ascii($0), at: 4)
            })
        {
            return DetectedContent(family: .video, displayName: "QuickTime movie")
        }
        if starts(header, with: [0x00, 0x00, 0x01, 0xBA]) {
            return DetectedContent(family: .video, displayName: "MPEG video")
        }
        if (header.count >= 377 && header[0] == 0x47 && header[188] == 0x47 && header[376] == 0x47)
            || (header.count >= 389 && header[4] == 0x47 && header[196] == 0x47 && header[388] == 0x47)
        {
            return DetectedContent(family: .video, displayName: "MPEG transport stream")
        }
        if starts(header, with: AudioInput.asfSignature) {
            return containsBytes(header, sequence: asfVideoStreamGUID)
                ? DetectedContent(family: .video, displayName: "Windows Media Video")
                : DetectedContent(family: .audio, displayName: "Windows Media Audio")
        }
        if starts(header, with: ascii("OggS")) {
            return containsBytes(header, sequence: [0x80] + ascii("theora"))
                ? DetectedContent(family: .video, displayName: "Ogg video")
                : DetectedContent(family: .audio, displayName: "Ogg audio")
        }
        return nil
    }

    private static func identifyAudio(_ header: [UInt8]) -> DetectedContent? {
        if starts(header, with: ascii("ID3")), header.count >= 10,
            header[3] < 0xFF, header[4] < 0xFF, header[6..<10].allSatisfy({ $0 < 0x80 })
        {
            return DetectedContent(family: .audio, displayName: "MP3")
        }
        if starts(header, with: ascii("fLaC")) { return DetectedContent(family: .audio, displayName: "FLAC") }
        if starts(header, with: ascii("caff")), header.count >= 8, header[4] == 0, header[5] == 1 {
            return DetectedContent(family: .audio, displayName: "CAF audio")
        }
        if ["RIFF", "RF64", "BW64"].contains(where: { starts(header, with: ascii($0)) }),
            starts(header, with: ascii("WAVE"), at: 8)
        {
            return DetectedContent(family: .audio, displayName: "WAV")
        }
        if starts(header, with: ascii("FORM")), starts(header, with: ascii("AIF"), at: 8) {
            return DetectedContent(family: .audio, displayName: "AIFF")
        }
        return nil
    }

    private static func identifyMPEGAudio(_ header: [UInt8]) -> DetectedContent? {
        guard header.count >= 4, header[0] == 0xFF, header[1] & 0xE0 == 0xE0, (header[1] & 0x18) != 0x08 else {
            return nil
        }
        if header[1] & 0x06 == 0 { return DetectedContent(family: .audio, displayName: "AAC audio") }
        guard (header[2] & 0xF0) != 0xF0, (header[2] & 0x0C) != 0x0C else { return nil }
        return DetectedContent(family: .audio, displayName: "MP3")
    }

    private static func identifyArchive(_ header: [UInt8]) -> DetectedContent? {
        if isZip(header) { return DetectedContent(family: .archive, displayName: "ZIP archive") }
        if starts(header, with: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) {
            return DetectedContent(family: .archive, displayName: "7-Zip archive")
        }
        if starts(header, with: [0x1F, 0x8B]) { return DetectedContent(family: .archive, displayName: "Gzip archive") }
        if starts(header, with: ascii("BZh")), header.count >= 10,
            (UInt8(ascii: "1")...UInt8(ascii: "9")).contains(header[3]),
            starts(header, with: [0x31, 0x41, 0x59, 0x26, 0x53, 0x59], at: 4)
        {
            return DetectedContent(family: .archive, displayName: "Bzip2 archive")
        }
        if starts(header, with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) {
            return DetectedContent(family: .archive, displayName: "XZ archive")
        }
        if starts(header, with: ascii("Rar!") + [0x1A, 0x07]) {
            return DetectedContent(family: .archive, displayName: "RAR archive")
        }
        if isTar(header) { return DetectedContent(family: .archive, displayName: "TAR archive") }
        return nil
    }

    private static func isSVGRoot(_ sourceText: String) -> Bool {
        var text = sourceText
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var cursor = text.startIndex
        while cursor < text.endIndex {
            while cursor < text.endIndex, text[cursor].isWhitespace { cursor = text.index(after: cursor) }
            let remaining = text[cursor...]
            if remaining.hasPrefix("<?") {
                guard let end = remaining.range(of: "?>") else { return false }
                cursor = end.upperBound
            } else if remaining.hasPrefix("<!--") {
                guard let end = remaining.range(of: "-->") else { return false }
                cursor = end.upperBound
            } else if remaining.lowercased().hasPrefix("<!doctype") {
                guard let end = remaining.firstIndex(of: ">") else { return false }
                cursor = text.index(after: end)
            } else {
                let lowered = remaining.lowercased()
                guard lowered.hasPrefix("<svg") else { return false }
                let after = lowered.index(lowered.startIndex, offsetBy: 4)
                guard after == lowered.endIndex else {
                    let next = lowered[after]
                    return next.isWhitespace || next == ">" || next == "/"
                }
                return true
            }
        }
        return false
    }

    private static func containsBytes(_ header: [UInt8], sequence: [UInt8]) -> Bool {
        guard !sequence.isEmpty, header.count >= sequence.count else { return false }
        let limit = header.count - sequence.count
        for index in 0...limit where header[index..<(index + sequence.count)].elementsEqual(sequence) {
            return true
        }
        return false
    }

    private static func uint16BE(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func uint32BE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }

    private static func uint32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func isFallbackVideo(_ header: [UInt8]) -> Bool {
        if starts(header, with: AudioInput.asfSignature) { return true }
        if starts(header, with: [0x00, 0x00, 0x01, 0xBA]) { return true }
        if (header.count >= 189 && header[0] == 0x47 && header[188] == 0x47)
            || (header.count >= 197 && header[4] == 0x47 && header[196] == 0x47)
        {
            return true
        }
        if starts(header, with: ascii(".RMF")) || starts(header, with: ascii("OggS")) { return true }
        if starts(header, with: [0x06, 0x0E, 0x2B, 0x34]) { return true }
        return header.count >= 8 && header[0] == 0x1F && header[1] == 0x07 && header[2] == 0x00
    }

    private static func isFallbackAudio(_ header: [UInt8]) -> Bool {
        let signatures: [[UInt8]] = [
            [0x0B, 0x77],
            [0x7F, 0xFE, 0x80, 0x01], [0xFE, 0x7F, 0x01, 0x80],
            [0x1F, 0xFF, 0xE8, 0x00], [0xFF, 0x1F, 0x00, 0xE8], [0x64, 0x58, 0x20, 0x25],
            ascii("wvpk"), ascii("MAC "), ascii("TTA1"), ascii("#!AMR"),
            ascii(".RMF"), [0x2E, 0x72, 0x61, 0xFD],
            [0x1A, 0x45, 0xDF, 0xA3],
        ]
        return signatures.contains { starts(header, with: $0) }
    }
}
