import Foundation
import MenuCatalog
import Testing

@testable import Engine

@Suite struct U2SettingsPlannerTests {
    @Test func savedSettingsMigrateAndRoundTrip() throws {
        let legacy = Data(#"{"image":{"jpegQuality":42},"video":{"gifWidth":600,"gifStartSeconds":2}}"#.utf8)
        var settings = try Settings.decode(legacy)
        #expect(settings.image.jpegQuality == 42)
        #expect(settings.video.gifWidth == 600)
        #expect(settings.image.backgroundMask == .subject)
        #expect(settings.video.backgroundMask == .person)
        #expect(settings.image.svgColors == 8)
        #expect(settings.text.pdfImageDPI == 144)
        #expect(settings.audio.extractedAudioBitrate == nil)
        #expect(settings.video.frameRateFilm == 24)
        #expect(settings.video.frameRateStandard == 30)
        #expect(settings.video.frameRateSmooth == 60)
        #expect(settings.audio.loudnessTarget == -14)
        #expect(settings.audio.loudnessStreaming == -16)
        #expect(settings.audio.loudnessBroadcast == -23)
        #expect(settings.video.gifStartSeconds == 2)
        #expect(settings.video.gifEndSeconds == 0)
        settings.image.backgroundMask = .person
        settings.image.svgColors = 4
        settings.image.gifDithering = .floydSteinberg
        settings.video.gifStartSeconds = 2.125
        settings.video.gifEndSeconds = 5.75
        settings.video.frameRateFilm = 25
        settings.audio.loudnessStreaming = -17.5
        settings.audio.extractedAudioBitrate = 160
        settings.text.pdfImageDPI = 300
        #expect(try Settings.decode(JSONEncoder().encode(settings)) == settings)
    }

    @Test func imageLeavesUseSavedFillMaskAndSVGColors() throws {
        var settings = Settings()
        settings.image.rotationFillsWithColor = true
        settings.image.rotationFill = .chromaBlue
        settings.image.backgroundMask = .person
        settings.image.backgroundBlurRadius = 31
        settings.image.svgColors = 3

        let rotate = try #require(ImagePlanner.operation(for: .imageRotate, preset: "right-90", settings: settings))
        let blur = try #require(ImagePlanner.operation(for: .imageBackground, preset: "blur", settings: settings))
        let svg = try #require(ImagePlanner.operation(for: .imageConvert, preset: "svg", settings: settings))
        #expect(rotate == .rotate(degrees: 90, fill: .chromaBlue))
        #expect(blur == .background(BackgroundOptions(mask: .person, fill: .blur(radius: 31))))
        #expect(svg == .convert(ImageConversion(format: .svg, svgColors: 3)))

        settings.image.rotationFillsWithColor = false
        #expect(
            ImagePlanner.operation(for: .imageRotate, preset: "right-90", settings: settings)
                == .rotate(degrees: 90, fill: nil))
    }

    @Test func videoLeavesUseSavedAnimationBackgroundAndExtractRate() throws {
        var settings = Settings()
        settings.video.gifWidth = 640
        settings.video.gifFrameRate = 20
        settings.video.gifColors = 96
        settings.image.gifDithering = .none
        settings.video.gifLoops = false
        settings.video.gifStartSeconds = 2.125
        settings.video.gifEndSeconds = 8.75
        settings.video.backgroundMask = .subject
        settings.image.backgroundBlurRadius = 40
        settings.audio.extractedAudioBitrate = 192

        var animation = AnimationRendering(width: 640, framesPerSecond: 20)
        animation.colors = 96
        animation.dithering = .none
        animation.loops = false
        animation.start = 2.125
        animation.end = 8.75
        #expect(VideoPlanner.options(for: .videoToGIF, preset: "settings", settings: settings) == .gif(animation))
        #expect(
            VideoPlanner.options(for: .videoToAnimatedWebP, preset: "settings", settings: settings) == .webP(animation))
        #expect(VideoPlanner.options(for: .videoToAPNG, preset: "settings", settings: settings) == .apng(animation))
        #expect(
            VideoPlanner.options(for: .videoBackground, preset: "blur", settings: settings)
                == .background(
                    VideoBackgroundRequest(
                        mask: .subject, fill: .blur(radius: 40),
                        transparentFormat: .hevcAlpha)))
        #expect(
            VideoPlanner.options(for: .videoExtractAudio, preset: "m4a", settings: settings)
                == .extractAudio(.m4aAAC, kilobits: 192))

        settings.video.gifEndSeconds = 2.125
        #expect(VideoPlanner.options(for: .videoToGIF, preset: "settings", settings: settings) == nil)
    }

    @Test func frameRateAndLoudnessMenuSlotsUseSavedValues() {
        var settings = Settings()
        settings.video.frameRateFilm = 23
        settings.video.frameRateStandard = 48
        settings.video.frameRateSmooth = 100
        settings.audio.loudnessTarget = -12.5
        settings.audio.loudnessStreaming = -18
        settings.audio.loudnessBroadcast = -24.25

        #expect(OperationPlanner.options(for: .videoFPS, preset: "24", settings: settings) == .video(.frameRate(23)))
        #expect(OperationPlanner.options(for: .videoFPS, preset: "30", settings: settings) == .video(.frameRate(48)))
        #expect(OperationPlanner.options(for: .videoFPS, preset: "60", settings: settings) == .video(.frameRate(100)))
        #expect(
            OperationPlanner.options(for: .audioNormalize, preset: "lufs-14", settings: settings)
                == .audio(.normalize(targetLoudness: -12.5)))
        #expect(
            OperationPlanner.options(for: .audioNormalize, preset: "lufs-16", settings: settings)
                == .audio(.normalize(targetLoudness: -18)))
        #expect(
            OperationPlanner.options(for: .audioNormalize, preset: "lufs-23", settings: settings)
                == .audio(.normalize(targetLoudness: -24.25)))

        settings.video.frameRateFilm = 0
        settings.video.frameRateStandard = 121
        settings.audio.loudnessTarget = -4
        settings.audio.loudnessStreaming = -41
        #expect(OperationPlanner.options(for: .videoFPS, preset: "24", settings: settings) == nil)
        #expect(OperationPlanner.options(for: .videoFPS, preset: "30", settings: settings) == nil)
        #expect(OperationPlanner.options(for: .audioNormalize, preset: "lufs-14", settings: settings) == nil)
        #expect(OperationPlanner.options(for: .audioNormalize, preset: "lufs-16", settings: settings) == nil)
    }

    @Test func pdfAndExtraRotationLeavesUseSavedValues() throws {
        var settings = Settings()
        settings.text.pdfImageDPI = 300
        settings.extraRotationDegrees = 37.5

        #expect(
            OperationPlanner.options(for: .pdfToImages, preset: "png", settings: settings)
                == .pdf(.toImages(.png, dpi: 300)))
        #expect(
            ImagePlanner.operation(for: .imageRotate, preset: "extra-angle", settings: settings)
                == .rotate(degrees: 37.5, fill: nil))
        #expect(
            VideoPlanner.options(for: .videoRotate, preset: "extra-angle", settings: settings)
                == .rotate(degrees: 37.5, fill: .black))
        settings.extraRotationDegrees = -37.5
        #expect(
            VideoPlanner.options(for: .videoRotate, preset: "extra-angle", settings: settings)
                == .rotate(degrees: 322.5, fill: .black))
    }
}
