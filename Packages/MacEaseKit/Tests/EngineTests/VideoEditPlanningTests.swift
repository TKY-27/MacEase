import Formats
import Foundation
import Testing

@testable import Engine

@Suite struct VideoEditPlanningTests {
    @Test(arguments: [0.0, -1, 0.49, 4.01, Double.nan, Double.infinity])
    func rejectsInvalidSpeed(speed: Double) {
        #expect(throws: EngineError.invalidInput(.invalidNumericParameter)) { try VideoTiming(start: 0, speed: speed) }
    }

    @Test func fractionalSpeedMapsBothTimelinesFromTheTrimOrigin() throws {
        let clock = try VideoTiming(start: 2_000_000_000, speed: 1.37)
        #expect(try clock.outputTime(3_370_000_000) == 3_000_000_000)
        #expect(try clock.sourceTime(3_000_000_000) == 3_370_000_000)
        #expect(throws: EngineError.invalidInput(.invalidNumericParameter)) { try clock.sourceTime(Int64.max) }
    }

    @Test(arguments: [(1920, 1080, 640, 360), (1080, 1920, 360, 640), (1080, 1080, 360, 360), (320, 240, 320, 240)])
    func lowResolutionPreservesAspectWithoutEnlarging(width: Int, height: Int, expectedWidth: Int, expectedHeight: Int)
        throws
    {
        let size = try VideoResize.lines(360).dimensions(width: width, height: height)
        #expect(size.width == expectedWidth && size.height == expectedHeight)
    }

    @Test func newPresetValuesPreserveExistingOverrides() throws {
        var settings = Settings()
        try settings.menuValues.set(63, for: "image.resize/percent-50")
        try settings.menuValues.set(900, for: "video.resize/1080p")
        let original = try JSONEncoder().encode(settings)
        settings = try JSONDecoder().decode(Settings.self, from: original)
        #expect(
            OperationPlanner.options(for: .imageResize, preset: "percent-50", settings: settings)
                == .image(.resize(ImageResize(size: .percent(63)))))
        #expect(
            OperationPlanner.options(for: .videoResize, preset: "1080p", settings: settings)
                == .video(.resize(.lines(900))))
        for edge in [360, 480, 720] {
            let options = OperationPlanner.options(for: .imageResize, preset: "long-\(edge)", settings: settings)
            #expect(options == .image(.resize(ImageResize(size: .longEdge(edge)))))
        }
        #expect(
            OperationPlanner.options(for: .videoResize, preset: "360p", settings: settings)
                == .video(.resize(.lines(360))))
        #expect(OperationPlanner.options(for: .videoSpeed, preset: "2", settings: settings) == .video(.speed(2)))
        #expect(OperationPlanner.options(for: .videoSpeed, preset: "4.1", settings: settings) == nil)
    }
}
