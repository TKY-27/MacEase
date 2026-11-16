public enum OperationID: String, Codable, CaseIterable, Sendable {
    case imageEdit = "image.edit"
    case imageEnhance = "image.enhance"
    case imageResize = "image.resize"
    case imageCompress = "image.compress"
    case imageConvert = "image.convert"
    case imageTraceSVG = "image.traceSVG"
    case imageHDRToSDR = "image.hdrToSDR"
    case imageRotate = "image.rotate"
    case imageFlip = "image.flip"
    case imageTrimBorders = "image.trimBorders"
    case imageBackground = "image.background"
    case imageStripMetadata = "image.stripMetadata"
    case imageOCR = "image.ocr"
    case imageToPDF = "image.toPDF"
    case imageIconSet = "image.iconSet"
    case imageAIRename = "image.aiRename"

    case videoResize = "video.resize"
    case videoEdit = "video.edit"
    case videoSpeed = "video.speed"
    case videoCompress = "video.compress"
    case videoRotate = "video.rotate"
    case videoFlip = "video.flip"
    case videoFPS = "video.fps"
    case videoRemoveAudio = "video.removeAudio"
    case videoConvert = "video.convert"
    case videoHDRToSDR = "video.hdrToSDR"
    case videoToGIF = "video.toGIF"
    case videoToAnimatedWebP = "video.toAnimatedWebP"
    case videoToAPNG = "video.toAPNG"
    case videoThumbnail = "video.thumbnail"
    case videoExtractAudio = "video.extractAudio"
    case videoSubtitles = "video.subtitles"
    case videoBackground = "video.background"

    case audioConvert = "audio.convert"
    case audioSubtitles = "audio.subtitles"
    case audioCompress = "audio.compress"
    case audioNormalize = "audio.normalize"
    case audioTrim = "audio.trim"
    case audioEnhance = "audio.enhance"

    case folderRemoveDuplicates = "folder.removeDuplicates"
    case folderRemoveEmpty = "folder.removeEmpty"
    case folderTree = "folder.tree"
    case folderRename = "folder.rename"
    case folderAIRename = "folder.aiRename"
    case folderDownloadMedia = "folder.downloadMedia"
    case folderAnalyze = "folder.analyze"
    case folderCompress = "folder.compress"
    case folderOrganize = "folder.organize"

    case archiveExtract = "archive.extract"
    case archiveHatchExtract = "archive.hatchExtract"
    case archiveBrowse = "archive.browse"

    case pdfMerge = "pdf.merge"
    case pdfEditPages = "pdf.editPages"
    case pdfToImages = "pdf.toImages"
    case pdfToText = "pdf.toText"
    case pdfCompress = "pdf.compress"
    case pdfRotate = "pdf.rotate"
    case pdfExtractPages = "pdf.extractPages"
    case pdfSplit = "pdf.split"
    case pdfAIRename = "pdf.aiRename"

    case textEdit = "text.edit"
    case textEncoding = "text.encoding"
    case textLineEndings = "text.lineEndings"
    case textConvert = "text.convert"
    case textJSON = "text.json"

    case documentConvert = "document.convert"
    case plistConvert = "plist.convert"

    case jarDecompile = "jar.decompile"

    case anyChecksum = "any.checksum"
    case anyShare = "any.share"
    case anyFindRelated = "any.findRelated"
    case anyProtect = "any.protect"
    case filesFinish = "files.finish"

    public var kind: FileKind {
        switch rawValue.prefix(while: { $0 != "." }) {
        case "image": .image
        case "video": .video
        case "audio": .audio
        case "folder": .folder
        case "archive": .archive
        case "pdf": .pdf
        case "text": .text
        case "document": .document
        case "plist": .plist
        case "jar": .jar
        default: .any
        }
    }
}

public enum OperationRequirement: String, Codable, Sendable {
    case appleIntelligence
    case java
}

extension OperationID {
    public var presets: [String] {
        switch self {
        case .imageResize, .imageCompress, .imageConvert, .videoResize, .videoCompress,
            .videoThumbnail, .videoSubtitles, .audioSubtitles:
            presetGroups.flatMap { $0 }
        case .imageRotate, .videoRotate: ["right-90", "left-90", "180"]
        case .imageFlip, .videoFlip: ["horizontal", "vertical"]
        case .imageBackground: ["remove", "green", "blue", "color", "blur", "color-key"]
        case .imageStripMetadata: ["all", "gps", "settings"]
        case .imageOCR: ["copy", "save", "show"]
        case .imageIconSet: ["icns", "appiconset", "ico"]
        case .videoFPS: ["24", "30", "60"]
        case .videoSpeed: ["0.5", "0.75", "1.25", "1.5", "2", "4"]
        case .videoConvert: ["mp4", "mov", "m4v", "mkv", "webm", "avi", "flv"]
        case .videoToGIF: ["settings", "x"]
        case .videoToAnimatedWebP: ["settings"]
        case .videoToAPNG: ["settings"]
        case .videoExtractAudio, .audioConvert: audioFormatPresets
        case .videoBackground: ["remove", "green", "blue", "color", "blur"]
        case .audioCompress: ["192", "128", "96", "64"]
        case .audioNormalize: ["lufs-14", "lufs-16", "lufs-23"]
        case .folderTree: ["copy", "txt", "md"]
        case .folderCompress: ["zip", "7z", "tar", "tar.gz"]
        case .pdfToImages: ["png", "jpeg", "tiff"]
        case .pdfRotate: ["right-90", "left-90", "180"]
        case .textEncoding: ["utf-8", "utf-8-bom", "utf-16", "shift-jis"]
        case .textLineEndings: ["lf", "crlf"]
        case .textConvert:
            [
                "csv-json", "csv-xml", "csv-html", "csv-md", "json-csv", "json-xml", "xml-json", "ini-json",
                "ini-xml", "html-pdf", "html-txt", "json-plist-xml", "json-plist-binary", "json-yaml", "json-toml",
                "yaml-json", "toml-json", "md-html", "md-pdf", "srt-vtt", "vtt-srt", "txt",
            ]
        case .documentConvert: ["pdf", "txt"]
        case .plistConvert: ["json"]
        case .textJSON: ["pretty", "minify", "sort"]
        case .anyChecksum: ["sha256", "md5", "sha1", "sha512"]
        default: []
        }
    }

    private var audioFormatPresets: [String] {
        switch self {
        case .audioConvert:
            ["mp3", "m4a-aac", "m4a-alac", "aac", "wav", "aiff", "flac", "ogg", "opus", "caf-pcm", "caf-alac"]
        default: ["original", "m4a", "m4a-alac", "mp3", "aac", "wav", "aiff", "flac", "ogg", "opus"]
        }
    }

    public var offersCustom: Bool {
        switch self {
        case .imageResize, .videoResize, .videoSpeed, .imageCompress, .videoCompress, .audioCompress: true
        default: false
        }
    }

    public var presetGroups: [[String]] {
        switch self {
        case .imageResize:
            [
                ["percent-75", "percent-50", "percent-25"],
                ["long-3840", "long-2560", "long-1920", "long-1080", "long-720", "long-480", "long-360"],
            ]
        case .imageCompress:
            [["discord", "x", "instagram", "email", "web"], ["quality-high", "quality-medium", "quality-low"]]
        case .imageConvert:
            [
                ["png", "jpeg", "heic", "webp", "avif", "jxl"], ["gif", "tiff", "bmp", "tga"],
                ["ico", "icns", "svg", "pdf"],
            ]
        case .videoResize:
            [["percent-50"], ["2160p", "1080p", "720p", "480p", "360p"]]
        case .videoCompress:
            [
                ["discord", "x", "instagram", "line", "email"], ["mb-10", "mb-25", "mb-50", "mb-100"],
                ["quality-high", "quality-medium", "quality-low"],
            ]
        case .videoThumbnail: [["first", "middle"], ["choose-frame"]]
        case .videoSubtitles, .audioSubtitles: [["srt", "vtt", "txt"], ["translated-srt"]]
        default: presets.isEmpty ? [] : [presets]
        }
    }

    public var maximumSelection: Int? {
        switch self {
        case .audioTrim, .pdfExtractPages, .pdfEditPages, .imageTraceSVG,
            .archiveBrowse, .folderDownloadMedia, .imageEnhance, .audioEnhance,
            .anyFindRelated, .anyProtect:
            1
        case .anyShare: 20
        default: nil
        }
    }

    public static let menuOrder: [OperationID] = [
        .imageEdit, .imageConvert, .imageHDRToSDR, .imageCompress, .imageResize, .imageEnhance,
        .imageRotate, .imageFlip, .imageBackground,
        .imageOCR, .imageToPDF, .imageIconSet, .imageTraceSVG, .imageTrimBorders, .imageStripMetadata,
        .imageAIRename,
        .videoEdit, .videoConvert, .videoToGIF, .videoToAnimatedWebP, .videoToAPNG, .videoHDRToSDR,
        .videoCompress, .videoResize, .videoRotate, .videoFlip, .videoSpeed, .videoRemoveAudio,
        .videoFPS, .videoBackground, .videoThumbnail, .videoExtractAudio, .videoSubtitles,
        .audioTrim, .audioEnhance, .audioConvert, .audioCompress, .audioNormalize, .audioSubtitles,
        .pdfEditPages, .pdfMerge, .pdfToImages, .pdfToText, .pdfCompress, .pdfRotate, .pdfExtractPages, .pdfSplit,
        .pdfAIRename,
        .documentConvert, .textConvert, .textEncoding, .textLineEndings, .textJSON, .plistConvert,
        .folderDownloadMedia, .folderOrganize, .folderCompress, .folderRename, .folderTree, .folderAnalyze,
        .folderRemoveDuplicates,
        .folderRemoveEmpty, .folderAIRename, .archiveHatchExtract, .archiveExtract, .archiveBrowse,
        .jarDecompile, .filesFinish, .anyShare, .anyFindRelated, .anyProtect, .anyChecksum,
    ]

    public var requirement: OperationRequirement? {
        switch self {
        case .imageAIRename, .folderAIRename, .pdfAIRename:
            .appleIntelligence
        case .jarDecompile: .java
        default: nil
        }
    }

    public var minimumSelection: Int {
        self == .pdfMerge ? 2 : 1
    }
}

extension OperationID {
    public var menuGroupOperation: OperationID {
        switch self {
        case .imageFlip: .imageRotate
        case .imageHDRToSDR: .imageConvert
        case .videoFlip: .videoRotate
        case .videoToGIF, .videoToAnimatedWebP, .videoToAPNG, .videoHDRToSDR: .videoConvert
        default: self
        }
    }

    public func menuGroupID(preset: String?) -> String {
        self == .textJSON ? "\(rawValue)/\(preset ?? "")" : menuGroupOperation.rawValue
    }

    private static let primaryMenuOrder: [OperationID] = [
        .imageEdit, .imageConvert, .imageCompress, .imageResize, .imageRotate, .imageBackground, .imageOCR,
        .videoEdit, .videoConvert, .videoCompress, .videoResize, .videoExtractAudio, .videoThumbnail, .videoSubtitles,
        .audioTrim, .audioEnhance, .audioConvert, .audioCompress, .audioNormalize, .audioSubtitles,
        .pdfEditPages, .pdfMerge, .pdfToImages, .pdfToText, .pdfCompress, .pdfRotate, .pdfExtractPages, .pdfSplit,
        .textConvert, .textJSON, .documentConvert, .plistConvert,
        .folderCompress, .folderRename, .folderOrganize, .folderAnalyze, .folderRemoveDuplicates, .folderRemoveEmpty,
        .archiveHatchExtract, .archiveExtract, .archiveBrowse,
    ]

    var primaryMenuRank: Int {
        Self.primaryMenuOrder.firstIndex(of: menuGroupOperation) ?? Self.primaryMenuOrder.count
    }

    public var defaultMenuPlacement: MenuPlacement {
        Self.primaryMenuOrder.contains(menuGroupOperation) ? .primary : .more
    }
}
