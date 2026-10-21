import Engine
import Foundation
import MenuCatalog
import Speech

/// Titles follow the app's language setting.
enum MenuStrings {
    static func operation(_ op: OperationID) -> String {
        switch op {
        case .imageHDRToSDR:
            String(localized: "menu.op.image.hdrToSDR", defaultValue: "SDR")
        case .videoHDRToSDR:
            String(localized: "menu.op.video.hdrToSDR", defaultValue: "SDR")
        case .audioSubtitles:
            String(localized: "menu.op.audio.subtitles", defaultValue: "Subtitles")
        default: lookup("menu.op.\(op.rawValue)")
        }
    }

    /// Outside the menu, titles drop their ellipsis.
    static func operationName(_ op: OperationID) -> String {
        let title = operation(op)
        for ellipsis in ["…", "..."] where title.hasSuffix(ellipsis) { return String(title.dropLast(ellipsis.count)) }
        return title
    }

    static func preset(_ op: OperationID, _ preset: String) -> String {
        if preset == MenuEntry.customPreset {
            return String(localized: "menu.preset.custom-size", defaultValue: "Custom Size…")
        }
        switch (op, preset) {
        case (.audioSubtitles, "srt"):
            return String(localized: "menu.preset.audio.subtitles.srt", defaultValue: "SRT")
        case (.audioSubtitles, "vtt"):
            return String(localized: "menu.preset.audio.subtitles.vtt", defaultValue: "WebVTT")
        case (.audioSubtitles, "txt"):
            return String(localized: "menu.preset.audio.subtitles.txt", defaultValue: "Plain Text")
        case (.audioSubtitles, "translated-srt"):
            return String(localized: "menu.preset.audio.subtitles.translated-srt", defaultValue: "Translated SRT")
        case (.videoThumbnail, "choose-frame"):
            return String(localized: "menu.preset.video.thumbnail.choose-frame", defaultValue: "Choose Frame…")
        case (.videoToGIF, "settings"):
            return String(localized: "menu.preset.video.toGIF.settings", defaultValue: "GIF")
        case (.videoToGIF, "x"):
            return String(localized: "menu.preset.video.toGIF.x-export", defaultValue: "GIF for X (15 MB)")
        case (.videoToAnimatedWebP, "settings"):
            return String(localized: "menu.preset.video.toAnimatedWebP.settings", defaultValue: "Animated WebP")
        case (.videoToAPNG, "settings"):
            return String(localized: "menu.preset.video.toAPNG.settings", defaultValue: "APNG")
        case (.imageFlip, "horizontal"), (.videoFlip, "horizontal"):
            return String(localized: "menu.preset.flip.horizontal", defaultValue: "Flip Horizontal")
        case (.imageFlip, "vertical"), (.videoFlip, "vertical"):
            return String(localized: "menu.preset.flip.vertical", defaultValue: "Flip Vertical")
        case (.textConvert, "txt"):
            return String(localized: "menu.preset.text.convert.target.txt", defaultValue: "TXT")
        case (.textConvert, "csv-json"), (.textConvert, "xml-json"), (.textConvert, "ini-json"):
            return String(localized: "menu.preset.text.convert.target.json", defaultValue: "JSON")
        case (.textConvert, "json-csv"):
            return String(localized: "menu.preset.text.convert.target.csv", defaultValue: "CSV")
        case (.textConvert, "csv-xml"), (.textConvert, "json-xml"), (.textConvert, "ini-xml"):
            return String(localized: "menu.preset.text.convert.target.xml", defaultValue: "XML")
        case (.textConvert, "csv-html"):
            return String(localized: "menu.preset.text.convert.target.html", defaultValue: "HTML")
        case (.textConvert, "csv-md"):
            return String(localized: "menu.preset.text.convert.target.markdown", defaultValue: "Markdown")
        default: break
        }
        return lookup("menu.preset.\(op.rawValue).\(preset)")
    }

    static func titles(settings: Settings) -> MenuTitles {
        MenuTitles(
            operation: operation,
            preset: { op, presetID in
                if presetID == "extra-angle" {
                    return String(
                        localized: "menu.preset.rotate.extra-angle",
                        defaultValue: "\(settings.extraRotationDegrees.formatted())°")
                }
                if op == .videoFPS, let rate = frameRates(settings)[presetID] {
                    return String(localized: "menu.preset.video.fps.value", defaultValue: "\(rate) fps")
                }
                if op == .audioNormalize, let loudness = loudnessTargets(settings)[presetID] {
                    return String(
                        localized: "menu.preset.audio.normalize.value", defaultValue: "\(loudness.formatted()) LUFS")
                }
                if op == .imageCompress || op == .videoCompress,
                    let platform = settings.platformPresets.first(where: { $0.id == presetID })
                {
                    let limits = op == .imageCompress ? platform.image : platform.video
                    if let bytes = limits?.maxBytes {
                        let megabytes = (Double(bytes) / bytesPerMegabyte).formatted()
                        let name = platform.name.localized(languageCode: Bundle.main.preferredLocalizations.first)
                        return String(
                            localized: "menu.preset.platform-size", defaultValue: "\(name) (\(megabytes) MB)")
                    }
                }
                return preset(op, presetID)
            }, kind: kind, speechAvailable: SpeechTranscriber.isAvailable)
    }

    private static let bytesPerMegabyte = 1_000_000.0

    static func frameRates(_ settings: Settings) -> [String: Int] {
        [
            "24": settings.video.frameRateFilm, "30": settings.video.frameRateStandard,
            "60": settings.video.frameRateSmooth,
        ]
    }

    static func loudnessTargets(_ settings: Settings) -> [String: Double] {
        [
            "lufs-14": settings.audio.loudnessTarget, "lufs-16": settings.audio.loudnessStreaming,
            "lufs-23": settings.audio.loudnessBroadcast,
        ]
    }

    static func kind(_ kind: FileKind) -> String {
        lookup("menu.kind.\(kind.rawValue)")
    }

    private static func lookup(_ key: String) -> String {
        let value = String(localized: String.LocalizationValue(key))
        assert(value != key, "Missing localization for \(key)")
        return value
    }
}
