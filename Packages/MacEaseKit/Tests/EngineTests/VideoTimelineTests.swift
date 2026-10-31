import Foundation
import Testing

@testable import Engine

@Suite struct VideoTimelineTests {
    @Test func legacyRecordsRetainRangeAndSettings() throws {
        let record = Data(#"{"start":1,"end":5,"speed":2,"trimMode":"keyframe"}"#.utf8)
        let edit = try JSONDecoder().decode(VideoEdit.self, from: record)
        #expect(edit.segments == nil)
        let timeline = try VideoTimeline(edit: edit, sourceDuration: 6)
        #expect(timeline.duration == 2)
        #expect(timeline.sourceTime(at: 0.5) == 2)
        #expect(timeline.segments[0].volume == 1)
        #expect(timeline.segments[0].adjustments.isIdentity)
    }

    @Test func reorderedAndDuplicatedRangesHaveDistinctOutputOccurrences() throws {
        let first = VideoSegment(start: 5, end: 7, speed: 2)
        let second = VideoSegment(start: 1, end: 3, speed: 0.5)
        let third = VideoSegment(start: 5, end: 7)
        var edit = VideoEdit()
        edit.segments = [first, second, third]
        let restored = try JSONDecoder().decode(VideoEdit.self, from: JSONEncoder().encode(edit))
        #expect(restored == edit)
        let timeline = try VideoTimeline(edit: restored, sourceDuration: 8)
        #expect(timeline.duration == 7)
        #expect(timeline.sourceTime(at: 0.5) == 6)
        #expect(timeline.sourceTime(at: 1) == 1)
        #expect(timeline.sourceTime(at: 3) == 2)
        #expect(timeline.sourceTime(at: 5) == 5)
        #expect(timeline.sourceTime(at: 7) == 7)
        #expect(timeline.segment(at: 5).id == third.id)
        #expect(timeline.outputTime(for: 6, segmentID: first.id) == 0.5)
        #expect(timeline.outputTime(for: 6, segmentID: third.id) == 6)
        #expect(timeline.outputTime(for: 4, segmentID: third.id) == nil)
    }

    @Test func invalidSegmentRecordsAreRejected() throws {
        let valid = VideoSegment(start: 0, end: 1)
        var invalidAdjustment = valid
        invalidAdjustment.adjustments[.exposure] = .nan
        let ranges: [[VideoSegment]] = [
            [], [VideoSegment(start: -1, end: 1)], [VideoSegment(start: 1, end: 1)],
            [VideoSegment(start: 0, end: 3)], [VideoSegment(start: 0, end: .infinity)],
            [VideoSegment(start: 0, end: 1, speed: 0)], [VideoSegment(start: 0, end: 1, speed: .nan)],
            [VideoSegment(start: 0, end: 1, volume: 1.1)], [valid, valid], [invalidAdjustment],
        ]
        for segments in ranges {
            var edit = VideoEdit()
            edit.segments = segments
            #expect(throws: EngineError.self) { try VideoTimeline(edit: edit, sourceDuration: 2) }
        }
    }

    @Test func colorChangesIncludeEverySegment() {
        var color = MediaAdjustments()
        color.style = .monochrome
        var edit = VideoEdit()
        edit.segments = [VideoSegment(start: 0, end: 1), VideoSegment(start: 1, end: 2, adjustments: color)]
        #expect(edit.changesColor)
        #expect(edit.changesAppearance)
        edit.segments?.removeLast()
        #expect(!edit.changesColor)
    }
    @Test func legacySegmentRecordsUseInitialSource() throws {
        let encoded = Data(
            #"{"id":"F776754A-28B9-45D4-9001-6659A97C6786","start":1,"end":2,"speed":1,"volume":1,"adjustments":{"style":"original","styleIntensity":1,"values":{}}}"#
                .utf8)
        let segment = try JSONDecoder().decode(VideoSegment.self, from: encoded)
        #expect(segment.sourceIndex == 0)
        #expect(segment.start == 1 && segment.end == 2)
    }

    @Test func segmentsValidateAgainstTheirOwnSourceDuration() throws {
        let folder = try AudioSignals.temporaryFolder()
        let first = folder.appending(path: "first.mp4")
        let second = folder.appending(path: "second.mp4")
        try Data([1]).write(to: first)
        try Data([2]).write(to: second)
        var edit = VideoEdit()
        edit.sources = [
            VideoEditSource(url: first, duration: 1, stamp: try MediaSourceStamp(url: first)),
            VideoEditSource(url: second, duration: 5, stamp: try MediaSourceStamp(url: second)),
        ]
        edit.segments = [VideoSegment(start: 0, end: 1), VideoSegment(start: 3, end: 5, sourceIndex: 1)]
        #expect(try VideoTimeline(edit: edit, sourceDuration: 1).duration == 3)
        edit.segments?[1].sourceIndex = 0
        #expect(throws: EngineError.self) { try VideoTimeline(edit: edit, sourceDuration: 1) }
        edit.segments?[1].sourceIndex = 2
        #expect(throws: EngineError.self) { try VideoTimeline(edit: edit, sourceDuration: 1) }
    }

}
