import Foundation

/// Element IDs from RFC 9559.
enum MatroskaID {
    static let ebml: UInt32 = 0x1A45_DFA3
    static let ebmlVersion: UInt32 = 0x4286
    static let ebmlReadVersion: UInt32 = 0x42F7
    static let ebmlMaxIDLength: UInt32 = 0x42F2
    static let ebmlMaxSizeLength: UInt32 = 0x42F3
    static let docType: UInt32 = 0x4282
    static let docTypeVersion: UInt32 = 0x4287
    static let docTypeReadVersion: UInt32 = 0x4285
    static let segment: UInt32 = 0x1853_8067
    static let seekHead: UInt32 = 0x114D_9B74
    static let seek: UInt32 = 0x4DBB
    static let seekID: UInt32 = 0x53AB
    static let seekPosition: UInt32 = 0x53AC
    static let info: UInt32 = 0x1549_A966
    static let timestampScale: UInt32 = 0x2AD7B1
    static let duration: UInt32 = 0x4489
    static let title: UInt32 = 0x7BA9
    static let muxingApp: UInt32 = 0x4D80
    static let writingApp: UInt32 = 0x5741
    static let tracks: UInt32 = 0x1654_AE6B
    static let trackEntry: UInt32 = 0xAE
    static let trackNumber: UInt32 = 0xD7
    static let trackUID: UInt32 = 0x73C5
    static let trackType: UInt32 = 0x83
    static let flagLacing: UInt32 = 0x9C
    static let codecID: UInt32 = 0x86
    static let codecPrivate: UInt32 = 0x63A2
    static let defaultDuration: UInt32 = 0x23E383
    static let name: UInt32 = 0x536E
    static let language: UInt32 = 0x22B59C
    static let languageBCP47: UInt32 = 0x22B59D
    static let codecDelay: UInt32 = 0x56AA
    static let seekPreRoll: UInt32 = 0x56BB
    static let video: UInt32 = 0xE0
    static let pixelWidth: UInt32 = 0xB0
    static let pixelHeight: UInt32 = 0xBA
    static let displayWidth: UInt32 = 0x54B0
    static let displayHeight: UInt32 = 0x54BA
    static let displayUnit: UInt32 = 0x54B2
    static let pixelCropTop: UInt32 = 0x54BB
    static let pixelCropBottom: UInt32 = 0x54AA
    static let pixelCropLeft: UInt32 = 0x54CC
    static let pixelCropRight: UInt32 = 0x54DD
    static let alphaMode: UInt32 = 0x53C0
    static let colour: UInt32 = 0x55B0
    static let transferCharacteristics: UInt32 = 0x55BA
    static let masteringMetadata: UInt32 = 0x55D0
    static let maxCLL: UInt32 = 0x55BC
    static let maxFALL: UInt32 = 0x55BD
    static let audio: UInt32 = 0xE1
    static let samplingFrequency: UInt32 = 0xB5
    static let channels: UInt32 = 0x9F
    static let bitDepth: UInt32 = 0x6264
    static let contentEncodings: UInt32 = 0x6D80
    static let contentEncoding: UInt32 = 0x6240
    static let contentCompression: UInt32 = 0x5034
    static let contentCompAlgo: UInt32 = 0x4254
    static let contentCompSettings: UInt32 = 0x4255
    static let cluster: UInt32 = 0x1F43_B675
    static let clusterTimestamp: UInt32 = 0xE7
    static let simpleBlock: UInt32 = 0xA3
    static let blockGroup: UInt32 = 0xA0
    static let block: UInt32 = 0xA1
    static let blockAdditions: UInt32 = 0x75A1
    static let blockMore: UInt32 = 0xA6
    static let blockAddID: UInt32 = 0xEE
    static let blockAdditional: UInt32 = 0xA5
    static let blockDuration: UInt32 = 0x9B
    static let discardPadding: UInt32 = 0x75A2
    static let maxBlockAdditionID: UInt32 = 0x55EE
    static let contentEncryption: UInt32 = 0x5035
    static let tags: UInt32 = 0x1254_C367
    static let tag: UInt32 = 0x7373
    static let targets: UInt32 = 0x63C0
    static let tagTrackUID: UInt32 = 0x63C5
    static let simpleTag: UInt32 = 0x67C8
    static let chapters: UInt32 = 0x1043_A770
    static let attachments: UInt32 = 0x1941_A469
    static let referenceBlock: UInt32 = 0xFB
    static let cues: UInt32 = 0x1C53_BB6B
    static let cuePoint: UInt32 = 0xBB
    static let cueTime: UInt32 = 0xB3
    static let cueTrackPositions: UInt32 = 0xB7
    static let cueTrack: UInt32 = 0xF7
    static let cueClusterPosition: UInt32 = 0xF1
    static let void: UInt32 = 0xEC
    static let crc32: UInt32 = 0xBF

    static let topLevel: Set<UInt32> = [seekHead, info, tracks, cluster, cues, tags, chapters, attachments]
}

/// Enumerated element values from RFC 9559.
enum MatroskaValue {
    static let videoTrack = 1
    static let audioTrack = 2
    static let headerStripping: UInt64 = 3
    static let alphaAdditionID: UInt64 = 1
}

/// Matroska CodecID strings and their codecs.
public enum MatroskaCodec {
    static func codec(id: String, bitDepth: Int?) -> MediaCodec {
        switch id {
        case "V_MPEG4/ISO/AVC": .h264
        case "V_MPEGH/ISO/HEVC": .hevc
        case "V_VP8": .vp8
        case "V_VP9": .vp9
        case "V_AV1": .av1
        case "V_MJPEG": .mjpeg
        case "V_PRORES": .prores
        case "A_ALAC": .alac
        case "V_MPEG4/ISO/ASP", "V_MPEG4/ISO/SP", "V_MPEG4/ISO/AP": .mpeg4Part2
        case "A_OPUS": .opus
        case "A_VORBIS": .vorbis
        case "A_FLAC": .flac
        case "A_MPEG/L3": .mp3
        case "A_AC3": .ac3
        case "A_PCM/INT/LIT": .pcm(bits: bitDepth ?? 16, float: false, bigEndian: false)
        case "A_PCM/INT/BIG": .pcm(bits: bitDepth ?? 16, float: false, bigEndian: true)
        case "A_PCM/FLOAT/IEEE": .pcm(bits: bitDepth ?? 32, float: true, bigEndian: false)
        case _ where id.hasPrefix("A_AAC"): .aac
        case _ where id.hasPrefix("A_DTS"): .unsupported("DTS")
        case _ where id.hasPrefix("A_TRUEHD"): .unsupported("Dolby TrueHD")
        case _ where id.hasPrefix("A_EAC3"): .unsupported("E-AC-3")
        default: .unsupported(id)
        }
    }

    public static func id(for codec: MediaCodec) throws -> String {
        switch codec {
        case .h264: "V_MPEG4/ISO/AVC"
        case .hevc: "V_MPEGH/ISO/HEVC"
        case .vp8: "V_VP8"
        case .vp9: "V_VP9"
        case .av1: "V_AV1"
        case .mjpeg: "V_MJPEG"
        case .mpeg4Part2: "V_MPEG4/ISO/ASP"
        case .prores: "V_PRORES"
        case .alac: "A_ALAC"
        case .aac: "A_AAC"
        case .opus: "A_OPUS"
        case .vorbis: "A_VORBIS"
        case .flac: "A_FLAC"
        case .mp3: "A_MPEG/L3"
        case .ac3: "A_AC3"
        case .pcm(_, let float, let bigEndian):
            float ? "A_PCM/FLOAT/IEEE" : bigEndian ? "A_PCM/INT/BIG" : "A_PCM/INT/LIT"
        case .unsupported(let name): throw FormatError.unsupported(name)
        }
    }

    static let webmCodecs: Set<String> = ["V_VP8", "V_VP9", "V_AV1", "A_OPUS", "A_VORBIS"]
}
