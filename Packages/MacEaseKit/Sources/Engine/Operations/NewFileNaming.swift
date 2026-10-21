import Foundation

enum NewFileNaming: Sendable {
    case conversion
    case edit(String)

    init?(options: OperationOptions) {
        switch options {
        case .image(let operation):
            switch operation {
            case .hdrToSDR: self = .edit("sdr")
            case .convert: self = .conversion
            case .resize: self = .edit("resized")
            case .compress: self = .edit("compressed")
            case .rotate: self = .edit("rotated")
            case .flip: self = .edit("flipped")
            case .trimBorders: self = .edit("cropped")
            case .background: self = .edit("nobg")
            case .stripMetadata: self = .edit("clean")
            case .ocr, .toPDF, .iconSet, .copyBase64: return nil
            }
        case .video(let operation):
            switch operation {
            case .hdrToSDR: self = .edit("sdr")
            case .convert: self = .conversion
            case .resize: self = .edit("resized")
            case .compress: self = .edit("compressed")
            case .rotate: self = .edit("rotated")
            case .flip: self = .edit("flipped")
            case .trim: self = .edit("trimmed")
            case .frameRate: self = .edit("fps")
            case .removeAudio: self = .edit("noaudio")
            case .extractAudio, .still, .gif, .apng, .webP, .gifX, .subtitles, .background: return nil
            }
        case .audio(let operation):
            switch operation {
            case .subtitles: return nil
            case .convert: self = .conversion
            case .compress: self = .edit("compressed")
            case .normalize: self = .edit("normalized")
            case .trim: self = .edit("trimmed")
            }
        case .pdf(let operation):
            switch operation {
            case .compress: self = .edit("compressed")
            case .rotate: self = .edit("rotated")
            case .merge, .toImages, .toText, .extractPages, .split: return nil
            }
        case .text(let operation):
            switch operation {
            case .encoding(let encoding, _):
                switch encoding {
                case .utf8: self = .edit("utf8")
                case .utf8BOM: self = .edit("utf8bom")
                case .utf16: self = .edit("utf16")
                case .shiftJIS: self = .edit("sjis")
                }
            case .lineEndings(let ending): self = .edit(ending.rawValue)
            case .json(let formatting):
                switch formatting {
                case .pretty: self = .edit("pretty")
                case .minify: self = .edit("min")
                case .sortKeys: self = .edit("sorted")
                }
            case .convert: return nil
            }
        case .checksum, .rename, .folder, .archive, .jar, .document, .plistToJSON: return nil
        }
    }

    func name(for original: URL, outputName: String) -> String {
        let pathExtension = (outputName as NSString).pathExtension
        let stem = original.deletingPathExtension().lastPathComponent
        let suffix: String
        switch self {
        case .conversion:
            suffix = pathExtension.lowercased() == original.pathExtension.lowercased() ? "_converted" : ""
        case .edit(let operation): suffix = "_\(operation)"
        }
        return stem + suffix + (pathExtension.isEmpty ? "" : ".\(pathExtension)")
    }
}
