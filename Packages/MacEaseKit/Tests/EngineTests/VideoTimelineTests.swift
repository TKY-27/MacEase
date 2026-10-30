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
}
