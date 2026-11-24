import AppKit
import SwiftUI
import XCTest

@testable import Engine
@testable import MacEase

extension MediaEditorModelTests {
    private struct CanvasRecorder {
        var selected: [UUID] = []
        var steps: [Int] = []
        var actions: [(UUID, TimelineAction)] = []
        var overlays: [UUID] = []
        var musicSelections = 0
    }

    func testTimelineCanvasExposesEveryDrawnPartWithMatchingFrames() throws {
        let first = UUID(), frozen = UUID(), reversed = UUID(), overlay = UUID()
        var zoom = 1.0
        var recorder = CanvasRecorder()
        let scroll = TimelineScrollView(frame: CGRect(x: 0, y: 0, width: 900, height: 180))
        scroll.documentView = TimelineCanvas()
        scroll.configuration = MediaTimeline(
            duration: 6, position: 1,
            clips: [
                TimelineClip(
                    id: first, range: 0...2, selection: nil, label: "",
                    accessibility: .segment(
                        index: 0, count: 3, sourceName: nil, freeze: false, reversed: false, speed: 1)),
                TimelineClip(
                    id: frozen, range: 2...4, selection: 2...4, label: "", freeze: true,
                    accessibility: .segment(
                        index: 1, count: 3, sourceName: nil, freeze: true, reversed: false, speed: 1)),
                TimelineClip(
                    id: reversed, range: 4...6, selection: nil, label: "",
                    accessibility: .segment(
                        index: 2, count: 3, sourceName: nil, freeze: false, reversed: true, speed: 2)),
            ],
            playing: false, zoom: Binding(get: { zoom }, set: { zoom = $0 }), maximumZoom: 100,
            seek: { _ in }, hover: { _ in }, select: { recorder.selected.append($0) }, beginTrim: { _, _ in },
            trim: { _ in }, endTrim: {}, action: { recorder.actions.append(($0, $1)) },
            actionState: { id, action in
                TimelineActionState(
                    available: action != .left || id != first, checked: action == .reverse && id == reversed)
            },
            overlays: [
                TimelineOverlayMark(
                    id: overlay, ranges: [0.5...1.5, 3...3.5], label: "Box 1", fill: .systemRed, text: .white,
                    selected: true)
            ],
            showsOverlayLane: true, selectOverlay: { recorder.overlays.append($0) }, hatched: [1...1.5],
            music: TimelineMusicBar(range: 0...3, label: "tone.wav", fadeOut: 0, volume: 0.3),
            selectMusic: { recorder.musicSelections += 1 }, step: { recorder.steps.append($0) })
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 900, height: 180), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }
        scroll.updateTimeline()
        let canvas = try XCTUnwrap(scroll.canvas)
        XCTAssertEqual(canvas.accessibilityRole(), .layoutArea)
        XCTAssertEqual(canvas.accessibilityLabel(), "Timeline")

        func elements() throws -> [String: NSAccessibilityElement] {
            let children = try XCTUnwrap(canvas.accessibilityChildren() as? [NSAccessibilityElement])
            return Dictionary(uniqueKeysWithValues: children.map { ($0.accessibilityLabel() ?? "", $0) })
        }
        func onScreen(_ rect: CGRect) -> CGRect { window.convertToScreen(canvas.convert(rect, to: nil)) }
        func assertFrame(
            _ element: NSAccessibilityElement?, _ local: CGRect, file: StaticString = #filePath, line: UInt = #line
        ) {
            let frame = element?.accessibilityFrame() ?? .null
            let expected = onScreen(local)
            for (actual, wanted) in [
                (frame.minX, expected.minX), (frame.minY, expected.minY), (frame.width, expected.width),
                (frame.height, expected.height),
            ] {
                XCTAssertEqual(actual, wanted, accuracy: 0.001, file: file, line: line)
            }
        }

        var parts = try elements()
        XCTAssertEqual(
            Set(parts.keys),
            [
                "Playhead", "Segment 1 of 3", "Segment 2 of 3", "Segment 3 of 3", "Box 1, part 1 of 2",
                "Box 1, part 2 of 2", "Music, tone.wav", "Pause to remove, 1 of 1",
            ])
        let width = canvas.bounds.width
        let x = { (seconds: Double) in seconds / 6 * width }
        let clipTop = TimelineCanvas.rulerHeight, clipHeight = TimelineCanvas.clipHeight
        let overlayTop = clipTop + clipHeight + 6
        assertFrame(parts["Segment 2 of 3"], CGRect(x: x(2), y: clipTop, width: x(2), height: clipHeight))
        assertFrame(parts["Pause to remove, 1 of 1"], CGRect(x: x(1), y: clipTop, width: x(0.5), height: clipHeight))
        assertFrame(
            parts["Box 1, part 2 of 2"],
            CGRect(x: x(3), y: overlayTop, width: x(0.5), height: TimelineCanvas.overlayLaneHeight - 4))
        assertFrame(
            parts["Music, tone.wav"],
            CGRect(
                x: 0, y: overlayTop + TimelineCanvas.overlayLaneHeight, width: x(3),
                height: TimelineCanvas.musicLaneHeight - 4))
        let lanes = TimelineCanvas.overlayLaneHeight + TimelineCanvas.musicLaneHeight
        assertFrame(
            parts["Playhead"],
            CGRect(x: x(1) - 6, y: 3, width: 12, height: clipTop - 6 + clipHeight + 12 + lanes - 4 - 3))

        XCTAssertEqual(parts["Playhead"]?.accessibilityRole(), .slider)
        XCTAssertEqual(
            parts["Playhead"]?.accessibilityValue() as? String, "\(Timecode.spoken(1)) of \(Timecode.spoken(6))")
        XCTAssertEqual(parts["Segment 2 of 3"]?.accessibilityRole(), .layoutItem)
        XCTAssertEqual(
            parts["Segment 2 of 3"]?.accessibilityValue() as? String,
            [Timecode.spokenRange(2...4), "Freeze Frame", "Selected"].formatted(.list(type: .and, width: .narrow)))
        XCTAssertEqual(parts["Segment 2 of 3"]?.isAccessibilitySelected(), true)
        XCTAssertEqual(parts["Segment 1 of 3"]?.isAccessibilitySelected(), false)
        XCTAssertEqual(
            parts["Segment 3 of 3"]?.accessibilityValue() as? String,
            [Timecode.spokenRange(4...6), "Reversed", "Speed 2×"].formatted(.list(type: .and, width: .narrow)))
        XCTAssertEqual(
            parts["Music, tone.wav"]?.accessibilityValue() as? String,
            [Timecode.spokenRange(0...3), "Volume 30%"].formatted(.list(type: .and, width: .narrow)))
        XCTAssertEqual(
            parts["Box 1, part 1 of 2"]?.accessibilityValue() as? String,
            [Timecode.spokenRange(0.5...1.5), "Selected"].formatted(.list(type: .and, width: .narrow)))
        XCTAssertTrue(Timecode.spoken(65.25).contains("5.25"))
        XCTAssertFalse(Timecode.spoken(65.25).contains("1:05"), "VoiceOver gets words, not a clock")

        XCTAssertTrue(try XCTUnwrap(parts["Segment 3 of 3"]).accessibilityPerformPress())
        XCTAssertTrue(try XCTUnwrap(parts["Box 1, part 2 of 2"]).accessibilityPerformPress())
        XCTAssertTrue(try XCTUnwrap(parts["Music, tone.wav"]).accessibilityPerformPress())
        XCTAssertFalse(try XCTUnwrap(parts["Pause to remove, 1 of 1"]).accessibilityPerformPress())
        XCTAssertTrue(try XCTUnwrap(parts["Playhead"]).accessibilityPerformIncrement())
        XCTAssertTrue(try XCTUnwrap(parts["Playhead"]).accessibilityPerformDecrement())
        XCTAssertEqual(recorder.selected, [reversed])
        XCTAssertEqual(recorder.overlays, [overlay])
        XCTAssertEqual(recorder.musicSelections, 1)
        XCTAssertEqual(recorder.steps, [1, -1])

        let firstActions = parts["Segment 1 of 3"]?.accessibilityCustomActions()?.map(\.name) ?? []
        XCTAssertEqual(firstActions, TimelineAction.allCases.filter { $0 != .left }.map(\.title))
        let reversedActions = try XCTUnwrap(parts["Segment 3 of 3"]?.accessibilityCustomActions())
        XCTAssertTrue(reversedActions.map(\.name).contains("Play Segment Forward"))
        XCTAssertFalse(reversedActions.map(\.name).contains(TimelineAction.reverse.title))
        let duplicate = try XCTUnwrap(reversedActions.first { $0.name == TimelineAction.duplicate.title })
        XCTAssertTrue(duplicate.handler?() ?? false)
        XCTAssertEqual(recorder.actions.map(\.0), [reversed])
        XCTAssertEqual(recorder.actions.map(\.1), [.duplicate])

        let center = onScreen(CGRect(x: x(4.5), y: clipTop + 40, width: 1, height: 1)).origin
        XCTAssertTrue((canvas.accessibilityHitTest(center) as? NSAccessibilityElement) === parts["Segment 3 of 3"])
        let knob = onScreen(CGRect(x: x(1), y: 8, width: 1, height: 1)).origin
        XCTAssertTrue((canvas.accessibilityHitTest(knob) as? NSAccessibilityElement) === parts["Playhead"])

        zoom = 4
        scroll.updateTimeline()
        scroll.contentView.scroll(to: CGPoint(x: 700, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        let zoomed = try elements()
        XCTAssertTrue(zoomed["Segment 2 of 3"] === parts["Segment 2 of 3"], "elements survive layout changes")
        let zoomedWidth = canvas.bounds.width
        XCTAssertEqual(zoomedWidth, width * 4, accuracy: 0.001)
        assertFrame(
            zoomed["Segment 2 of 3"],
            CGRect(x: 2 / 6 * zoomedWidth, y: clipTop, width: 2 / 6 * zoomedWidth, height: clipHeight))
        XCTAssertEqual(
            try XCTUnwrap(zoomed["Segment 2 of 3"]).accessibilityFrame().minX,
            window.convertToScreen(CGRect(x: 2 / 6 * zoomedWidth - 700, y: 0, width: 1, height: 1)).minX,
            accuracy: 0.001, "frames follow scrolling")

        canvas.interactionEnabled = false
        parts = try elements()
        XCTAssertEqual(parts["Segment 1 of 3"]?.accessibilityCustomActions()?.isEmpty, true)
        XCTAssertFalse(try XCTUnwrap(parts["Segment 1 of 3"]).accessibilityPerformPress())
        XCTAssertFalse(try XCTUnwrap(parts["Playhead"]).accessibilityPerformIncrement())
        XCTAssertFalse(try XCTUnwrap(parts["Segment 1 of 3"]).isAccessibilityEnabled())
        XCTAssertFalse(duplicate.handler?() ?? true, "a stale action cannot bypass the lock")
        XCTAssertEqual(recorder.selected, [reversed])
        XCTAssertEqual(recorder.steps, [1, -1])
        XCTAssertEqual(recorder.actions.count, 1)
    }

    func testTimelineExposesOnlyNamedClipsAndRevealsAMovedPlayhead() throws {
        var zoom = 8.0
        var position = 0.5
        var revealRequest: UUID?
        let scroll = TimelineScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 120))
        scroll.documentView = TimelineCanvas()
        func configure() {
            scroll.configuration = MediaTimeline(
                duration: 10, position: position,
                clips: [TimelineClip(id: UUID(), range: 0...10, selection: 0...10, label: "")], playing: false,
                revealRequest: revealRequest, zoom: Binding(get: { zoom }, set: { zoom = $0 }), maximumZoom: 100,
                seek: { _ in }, hover: { _ in }, select: { _ in }, beginTrim: { _, _ in }, trim: { _ in }, endTrim: {},
                accessibilityTitle: "Waveform")
            scroll.updateTimeline()
        }
        configure()
        let canvas = try XCTUnwrap(scroll.canvas)
        let children = try XCTUnwrap(canvas.accessibilityChildren() as? [NSAccessibilityElement])
        XCTAssertEqual(children.map { $0.accessibilityLabel() }, ["Playhead"], "unnamed clips stay hidden")
        XCTAssertEqual(canvas.accessibilityLabel(), "Waveform")
        let start = scroll.contentView.bounds
        position = 9
        revealRequest = UUID()
        configure()
        let playhead = 9.0 / 10 * canvas.bounds.width
        XCTAssertFalse(start.contains(CGPoint(x: playhead, y: 10)))
        XCTAssertTrue(
            scroll.contentView.bounds.contains(CGPoint(x: playhead, y: 10)),
            "a keyboard step past the edge scrolls the playhead into view")
    }

    func testStaleAccessibilityActionsAndPressesRevalidateAtPerformTime() async throws {
        let model = try await videoModel(count: 2)
        model.seek(0.5)
        let host = NSHostingView(rootView: EditorTimeline(model: model))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1200, height: 220), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let canvas = try XCTUnwrap(timelineView(in: host)?.canvas)
        let children = try XCTUnwrap(canvas.accessibilityChildren() as? [NSAccessibilityElement])
        let firstSegment = try XCTUnwrap(children.first { $0.accessibilityLabel() == "Segment 1 of 2, clip-0.mp4" })
        let cachedFreeze = try XCTUnwrap(
            firstSegment.accessibilityCustomActions()?.first { $0.name == TimelineAction.freeze.title })

        let secondID = model.values.segments[1].id
        model.selectSegment(secondID)
        model.seek(2.5)
        host.layoutSubtreeIfNeeded()
        let before = model.values.segments
        XCTAssertFalse(cachedFreeze.handler?() ?? true, "cached freeze action must fail once playhead left segment 1")
        XCTAssertEqual(model.values.segments, before)
        XCTAssertEqual(model.values.selectedID, secondID)

        let clipID = UUID(), overlayID = UUID()
        var zoom = 1.0
        var recorder = CanvasRecorder()
        let scroll = TimelineScrollView(frame: CGRect(x: 0, y: 0, width: 900, height: 180))
        scroll.documentView = TimelineCanvas()
        scroll.configuration = MediaTimeline(
            duration: 6, position: 1,
            clips: [
                TimelineClip(
                    id: clipID, range: 0...6, selection: nil, label: "",
                    accessibility: .segment(
                        index: 0, count: 1, sourceName: nil, freeze: false, reversed: false, speed: 1))
            ],
            playing: false, zoom: Binding(get: { zoom }, set: { zoom = $0 }), maximumZoom: 100, seek: { _ in },
            hover: { _ in }, select: { recorder.selected.append($0) }, beginTrim: { _, _ in }, trim: { _ in },
            endTrim: {}, action: { recorder.actions.append(($0, $1)) },
            overlays: [
                TimelineOverlayMark(
                    id: overlayID, ranges: [1...2], label: "Box 1", fill: .systemRed, text: .white, selected: false)
            ],
            showsOverlayLane: true, selectOverlay: { recorder.overlays.append($0) },
            music: TimelineMusicBar(range: 0...3, label: "tone.wav", fadeOut: 0, volume: 0.3),
            selectMusic: { recorder.musicSelections += 1 })
        scroll.updateTimeline()
        let detachedCanvas = try XCTUnwrap(scroll.canvas)
        let detachedChildren = try XCTUnwrap(detachedCanvas.accessibilityChildren() as? [NSAccessibilityElement])
        let clipElement = try XCTUnwrap(detachedChildren.first { $0.accessibilityLabel() == "Segment 1 of 1" })
        let overlayElement = try XCTUnwrap(detachedChildren.first { $0.accessibilityLabel() == "Box 1" })
        let musicElement = try XCTUnwrap(detachedChildren.first { $0.accessibilityLabel() == "Music, tone.wav" })
        let duplicateAction = try XCTUnwrap(
            clipElement.accessibilityCustomActions()?.first { $0.name == TimelineAction.duplicate.title })

        scroll.configuration = MediaTimeline(
            duration: 6, position: 1,
            clips: [
                TimelineClip(
                    id: UUID(), range: 0...6, selection: nil, label: "",
                    accessibility: .segment(
                        index: 0, count: 1, sourceName: nil, freeze: false, reversed: false, speed: 1))
            ],
            playing: false, zoom: Binding(get: { zoom }, set: { zoom = $0 }), maximumZoom: 100, seek: { _ in },
            hover: { _ in }, select: { recorder.selected.append($0) }, beginTrim: { _, _ in }, trim: { _ in },
            endTrim: {}, action: { recorder.actions.append(($0, $1)) }, overlays: [], showsOverlayLane: true,
            selectOverlay: { recorder.overlays.append($0) }, music: nil,
            selectMusic: { recorder.musicSelections += 1 })
        scroll.updateTimeline()

        XCTAssertFalse(clipElement.accessibilityPerformPress())
        XCTAssertFalse(overlayElement.accessibilityPerformPress())
        XCTAssertFalse(musicElement.accessibilityPerformPress())
        XCTAssertFalse(duplicateAction.handler?() ?? true)
        XCTAssertTrue(recorder.selected.isEmpty)
        XCTAssertTrue(recorder.overlays.isEmpty)
        XCTAssertEqual(recorder.musicSelections, 0)
        XCTAssertTrue(recorder.actions.isEmpty)
    }

    func testEmptyTimelineExposesNoChildrenAndAnnouncesWhenPopulated() async throws {
        let directory = try workspace()
        let model = try await videoModel()
        model.setMusic(try audioFixture(in: directory))
        await model.musicTask?.value
        model.deleteSelection()
        let host = NSHostingView(rootView: EditorTimeline(model: model))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1000, height: 220), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let editorCanvas = try XCTUnwrap(timelineView(in: host)?.canvas)
        XCTAssertEqual((editorCanvas.accessibilityChildren() as? [NSAccessibilityElement])?.count, 0)

        let audioModel = AudioTrimModel(
            url: try audioFixture(in: directory), staging: StagingArea(supportDirectory: directory), prefill: nil)
        addTeardownBlock { await audioModel.close() }
        let audioHost = NSHostingView(rootView: AudioTrimPanel(model: audioModel, cancel: {}, run: { _ in }))
        let audioWindow = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 320), styleMask: [.titled],
            backing: .buffered, defer: false)
        audioWindow.isReleasedWhenClosed = false
        audioWindow.contentView = audioHost
        defer { audioWindow.close() }
        audioHost.layoutSubtreeIfNeeded()
        let audioCanvas = try XCTUnwrap(timelineView(in: audioHost)?.canvas)
        XCTAssertEqual((audioCanvas.accessibilityChildren() as? [NSAccessibilityElement])?.count, 0)

        var zoom = 1.0
        var notifications: [NSAccessibility.Notification] = []
        let observed = TimelineCanvas(frame: CGRect(x: 0, y: 0, width: 600, height: 120))
        observed.postAccessibilityNotification = { notification, _ in notifications.append(notification) }
        observed.configuration = MediaTimeline(
            duration: 0, position: 0, clips: [], playing: false,
            zoom: Binding(get: { zoom }, set: { zoom = $0 }), maximumZoom: 100, seek: { _ in }, hover: { _ in },
            select: { _ in }, beginTrim: { _, _ in }, trim: { _ in }, endTrim: {})
        XCTAssertEqual((observed.accessibilityChildren() as? [NSAccessibilityElement])?.count, 0)
        notifications.removeAll()
        observed.configuration = MediaTimeline(
            duration: 5, position: 0,
            clips: [
                TimelineClip(
                    id: UUID(), range: 0...5, selection: nil, label: "",
                    accessibility: .segment(
                        index: 0, count: 1, sourceName: nil, freeze: false, reversed: false, speed: 1))
            ],
            playing: false, zoom: Binding(get: { zoom }, set: { zoom = $0 }), maximumZoom: 100, seek: { _ in },
            hover: { _ in }, select: { _ in }, beginTrim: { _, _ in }, trim: { _ in }, endTrim: {})
        XCTAssertEqual(notifications, [.layoutChanged])
        XCTAssertEqual((observed.accessibilityChildren() as? [NSAccessibilityElement])?.count, 2)
    }

    func testTimelineAccessibilitySharesLayoutAndStaysSilentOnPlaybackTicks() throws {
        var zoom = 4.0
        var position = 1.0
        let clips = (0..<300).map { index in
            TimelineClip(
                id: UUID(), range: Double(index)...Double(index + 1), selection: nil, label: "\(index + 1)",
                accessibility: .segment(
                    index: index, count: 300, sourceName: nil, freeze: false, reversed: false, speed: 1))
        }
        let overlays = (0..<50).map { index -> TimelineOverlayMark in
            let start = Double(index * 5)
            return TimelineOverlayMark(
                id: UUID(), ranges: [start...(start + 3), (start + 4)...(start + 6)],
                label: "Box \(index + 1)", fill: .systemRed, text: .white, selected: index == 49)
        }
        let scroll = TimelineScrollView(frame: CGRect(x: 0, y: 0, width: 1200, height: 180))
        var notifications: [NSAccessibility.Notification] = []
        let canvas = TimelineCanvas()
        canvas.postAccessibilityNotification = { notification, _ in notifications.append(notification) }
        scroll.documentView = canvas
        func makeConfig(playing: Bool) -> MediaTimeline {
            MediaTimeline(
                duration: 300, position: position, clips: clips, playing: playing,
                zoom: Binding(get: { zoom }, set: { zoom = $0 }), maximumZoom: 100, seek: { _ in }, hover: { _ in },
                select: { _ in }, beginTrim: { _, _ in }, trim: { _ in }, endTrim: {}, overlays: overlays,
                showsOverlayLane: true, selectOverlay: { _ in })
        }
        scroll.configuration = makeConfig(playing: false)
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 1200, height: 180), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }
        scroll.updateTimeline()

        for tick in 1...10 {
            position = Double(tick) / 30.0
            scroll.configuration = makeConfig(playing: true)
            scroll.updateTimeline()
        }
        XCTAssertTrue(notifications.isEmpty, "no notifications before VoiceOver queries children")

        let children = try XCTUnwrap(canvas.accessibilityChildren() as? [NSAccessibilityElement])
        XCTAssertEqual(children.count, 401)
        let lastClipPoint = window.convertToScreen(
            canvas.convert(
                CGRect(x: 299.5 / 300.0 * canvas.bounds.width, y: TimelineCanvas.rulerHeight + 30, width: 1, height: 1),
                to: nil
            )
        ).origin
        let hitClip = try XCTUnwrap(canvas.accessibilityHitTest(lastClipPoint) as? NSAccessibilityElement)
        XCTAssertEqual(hitClip.accessibilityLabel(), "Segment 300 of 300")
        XCTAssertTrue(hitClip === children.last)

        notifications.removeAll()
        for tick in 11...20 {
            position = Double(tick) / 30.0
            scroll.configuration = makeConfig(playing: true)
            scroll.updateTimeline()
        }
        XCTAssertTrue(notifications.isEmpty, "playback ticks with unchanged structure post no notifications")

        position = 5.0
        scroll.configuration = makeConfig(playing: false)
        scroll.updateTimeline()
        XCTAssertEqual(notifications, [.valueChanged])
    }

    private func sendHorizontalScrollWheel(to scroll: TimelineScrollView, deltaX: Int32 = -120) throws {
        let cgEvent = try XCTUnwrap(
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: deltaX, wheel3: 0))
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
        scroll.scrollWheel(with: event)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition())
    }

    func testPlayheadFollowRulePagesWithoutFightingManualScrollOrTrim() throws {
        var zoom = 8.0
        var position = 0.0
        var playing = false
        var trimming = false
        var revealRequest: UUID?
        let clipID = UUID()
        let scroll = TimelineScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 120))
        scroll.documentView = TimelineCanvas()
        func configure() {
            scroll.configuration = MediaTimeline(
                duration: 10, position: position,
                clips: [TimelineClip(id: clipID, range: 0...10, selection: 0...10, label: "")], playing: playing,
                trimming: trimming, revealRequest: revealRequest, zoom: Binding(get: { zoom }, set: { zoom = $0 }),
                maximumZoom: 100, seek: { _ in }, hover: { _ in }, select: { _ in }, beginTrim: { _, _ in },
                trim: { _ in }, endTrim: {})
            scroll.updateTimeline()
        }
        configure()

        playing = true
        configure()
        XCTAssertEqual(scroll.contentView.bounds.minX, 0)
        for next in [0.4, 0.8, 1.2] {
            position = next
            configure()
            XCTAssertEqual(scroll.contentView.bounds.minX, 0, "ticks inside the visible area never scroll")
        }

        position = 1.3
        configure()
        let pagedOrigin = scroll.contentView.bounds.minX
        XCTAssertGreaterThan(pagedOrigin, 500)
        XCTAssertTrue(scroll.contentView.bounds.contains(CGPoint(x: 1.3 / 10 * 4800, y: 10)))
        for next in [1.5, 2.0, 2.4] {
            position = next
            configure()
            XCTAssertEqual(scroll.contentView.bounds.minX, pagedOrigin, "no scroll again until leaving the new page")
        }

        try sendHorizontalScrollWheel(to: scroll)
        scroll.contentView.scroll(to: CGPoint(x: 3000, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        for next in [2.6, 3.0, 4.0] {
            position = next
            configure()
            XCTAssertEqual(scroll.contentView.bounds.minX, 3000, "manual scroll is not pulled back during playback")
        }

        playing = false
        configure()
        playing = true
        configure()
        position = 4.2
        configure()
        XCTAssertEqual(scroll.contentView.bounds.minX, 3000, "starting playback with playhead off-screen stays put")

        playing = false
        position = 1.0
        revealRequest = UUID()
        configure()
        XCTAssertTrue(scroll.contentView.bounds.contains(CGPoint(x: 1.0 / 10 * 4800, y: 10)))
        playing = true
        configure()
        position = 5.0
        configure()
        XCTAssertTrue(
            scroll.contentView.bounds.contains(CGPoint(x: 5.0 / 10 * 4800, y: 10)),
            "explicit move re-enabled following for subsequent playback")

        playing = false
        trimming = true
        let originBeforeTrim = scroll.contentView.bounds.minX
        position = 9.5
        revealRequest = UUID()
        configure()
        XCTAssertEqual(scroll.contentView.bounds.minX, originBeforeTrim, "trimming never scrolls the timeline")
    }

    func testExplicitRevealAndUnfollowedPlaybackEndInEditorAndAudioTrimmer() async throws {
        let model = try await videoModel()
        model.timelineZoom = 8
        let editorHost = NSHostingView(rootView: EditorTimeline(model: model))
        let editorWindow = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 220), styleMask: [.titled],
            backing: .buffered, defer: false)
        editorWindow.isReleasedWhenClosed = false
        editorWindow.contentView = editorHost
        defer { editorWindow.close() }
        editorHost.layoutSubtreeIfNeeded()
        let editorScroll = try XCTUnwrap(timelineView(in: editorHost))
        let editorCanvas = try XCTUnwrap(editorScroll.canvas)

        model.seek(0.4)
        editorHost.layoutSubtreeIfNeeded()
        model.play()
        editorHost.layoutSubtreeIfNeeded()
        try sendHorizontalScrollWheel(to: editorScroll)
        let farRightEditor = max(0, editorCanvas.bounds.width - editorScroll.contentView.bounds.width)
        editorScroll.contentView.scroll(to: CGPoint(x: farRightEditor, y: 0))
        editorScroll.reflectScrolledClipView(editorScroll.contentView)
        XCTAssertFalse(editorScroll.contentView.bounds.contains(CGPoint(x: 0, y: 10)))

        model.seek(0)
        editorHost.layoutSubtreeIfNeeded()
        XCTAssertTrue(
            editorScroll.contentView.bounds.contains(CGPoint(x: 0, y: 10)),
            "explicit seek to 0:00 during unfollowed playback reveals the playhead")

        model.seek(1.75)
        editorHost.layoutSubtreeIfNeeded()
        model.play()
        editorHost.layoutSubtreeIfNeeded()
        try sendHorizontalScrollWheel(to: editorScroll, deltaX: 120)
        editorScroll.contentView.scroll(to: .zero)
        editorScroll.reflectScrolledClipView(editorScroll.contentView)
        try await waitUntil { !model.playing }
        editorHost.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            editorScroll.contentView.bounds.minX, 0, accuracy: 1,
            "unfollowed playback reaching the end in the editor must not yank the view")

        let directory = try workspace()
        let audioModel = AudioTrimModel(
            url: try audioFixture(in: directory), staging: StagingArea(supportDirectory: directory),
            prefill: 0.2...0.5)
        addTeardownBlock { await audioModel.close() }
        await audioModel.load()
        XCTAssertTrue(audioModel.ready)
        audioModel.zoom = 8
        let audioHost = NSHostingView(rootView: AudioTrimPanel(model: audioModel, cancel: {}, run: { _ in }))
        let audioWindow = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 320), styleMask: [.titled],
            backing: .buffered, defer: false)
        audioWindow.isReleasedWhenClosed = false
        audioWindow.contentView = audioHost
        defer { audioWindow.close() }
        audioHost.layoutSubtreeIfNeeded()
        let audioScroll = try XCTUnwrap(timelineView(in: audioHost))
        let audioCanvas = try XCTUnwrap(audioScroll.canvas)

        audioModel.play()
        audioHost.layoutSubtreeIfNeeded()
        try sendHorizontalScrollWheel(to: audioScroll)
        let farRightAudio = max(0, audioCanvas.bounds.width - audioScroll.contentView.bounds.width)
        audioScroll.contentView.scroll(to: CGPoint(x: farRightAudio, y: 0))
        audioScroll.reflectScrolledClipView(audioScroll.contentView)
        try await waitUntil { !audioModel.playing }
        audioHost.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            audioScroll.contentView.bounds.minX, farRightAudio, accuracy: 1,
            "reaching Play Selection out point after manual scroll must not yank the view")

        audioModel.seek(audioModel.start)
        audioHost.layoutSubtreeIfNeeded()
        let startX = audioModel.start / audioModel.duration * audioCanvas.bounds.width
        XCTAssertTrue(
            audioScroll.contentView.bounds.contains(CGPoint(x: startX, y: 10)),
            "explicit seek in Audio Trimmer reveals the playhead")
    }

    func testWideningTimelineOnLastPageKeepsFollowingWhileScrollerDragStopsIt() throws {
        var zoom = 8.0
        var position = 9.0
        var playing = false
        let revealRequest: UUID? = UUID()
        let clipID = UUID()
        let scroll = TimelineScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 120))
        scroll.hasHorizontalScroller = true
        scroll.documentView = TimelineCanvas()
        func configure() {
            scroll.configuration = MediaTimeline(
                duration: 10, position: position,
                clips: [TimelineClip(id: clipID, range: 0...10, selection: 0...10, label: "")], playing: playing,
                revealRequest: revealRequest, zoom: Binding(get: { zoom }, set: { zoom = $0 }), maximumZoom: 100,
                seek: { _ in }, hover: { _ in }, select: { _ in }, beginTrim: { _, _ in }, trim: { _ in }, endTrim: {})
            scroll.updateTimeline()
        }
        configure()
        playing = true
        configure()
        let canvas = try XCTUnwrap(scroll.canvas)
        XCTAssertTrue(scroll.contentView.bounds.contains(CGPoint(x: 9.0 / 10 * canvas.bounds.width, y: 10)))

        scroll.setFrameSize(NSSize(width: 900, height: 120))
        scroll.layoutSubtreeIfNeeded()
        position = 0.5
        configure()
        XCTAssertTrue(
            scroll.contentView.bounds.contains(CGPoint(x: 0.5 / 10 * canvas.bounds.width, y: 10)),
            "widening the view on the last page must keep playhead following on")

        let scroller = try XCTUnwrap(scroll.horizontalScroller)
        _ = scroller.sendAction(scroller.action, to: scroller.target)
        scroll.contentView.scroll(to: CGPoint(x: 5000, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        position = 1.5
        configure()
        XCTAssertEqual(scroll.contentView.bounds.minX, 5000, "dragging the scroller turns playhead following off")
    }

    func testSelectingUnknownTargetsLeavesModelSelectionUnchanged() async throws {
        let model = try await videoModel()
        let originalSegment = try XCTUnwrap(model.values.selectedID)
        model.selectSegment(UUID())
        XCTAssertEqual(model.values.selectedID, originalSegment)

        model.addDefaultOverlay(.box)
        let originalOverlay = try XCTUnwrap(model.values.selectedOverlayID)
        model.selectOverlay(UUID())
        XCTAssertEqual(model.values.selectedOverlayID, originalOverlay)
        model.selectOverlay(nil)
        XCTAssertNil(model.values.selectedOverlayID)

        model.category = .markup
        model.musicRevealRequest = nil
        model.selectMusic()
        XCTAssertEqual(model.category, .markup)
        XCTAssertNil(model.musicRevealRequest)
    }

    func testSegmentListMutationsAreRefusedWhileTrimming() async throws {
        let model = try await videoModel(count: 2)
        let before = model.values.segments
        model.seek(0.5)
        model.beginTimelineTrim(before[0].id, start: true)
        XCTAssertTrue(model.trimming)
        let trimmedID = before[0].id
        XCTAssertEqual(model.values.selectedID, trimmedID)

        model.duplicateSelection()
        model.deleteSelection()
        model.moveSelection(1)
        model.moveSegment(trimmedID, to: 1)
        model.split()
        XCTAssertEqual(model.values.segments, before)
        XCTAssertEqual(model.values.selectedID, trimmedID)
        XCTAssertEqual(model.timelineRanges().count, before.count)
        await model.endTimelineTrim()
        XCTAssertFalse(model.trimming)
    }

    func testCShortcutSelectsSegmentAtPlayheadAndDefersToTextAndLock() async throws {
        let model = try await videoModel(count: 2)
        let firstID = model.values.segments[0].id
        let secondID = model.values.segments[1].id
        model.selectSegment(firstID)
        model.seek(2.5)

        let shortcut = EditorKeyboardShortcuts.ShortcutView()
        shortcut.model = model
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 150, height: 24))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 80), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
        container.addSubview(shortcut)
        container.addSubview(field)
        window.contentView = container
        defer { shortcut.stopMonitoring(); window.close() }

        try sendEditorKey("c", window: window)
        XCTAssertEqual(model.values.selectedID, secondID, "C selects the segment under the playhead")

        model.seek(0.5)
        XCTAssertTrue(window.makeFirstResponder(field))
        try sendEditorKey("c", window: window)
        XCTAssertEqual(model.values.selectedID, secondID, "C is ignored while a text field has focus")

        window.makeFirstResponder(nil)
        model.toggleReverse()
        XCTAssertTrue(model.editingLocked)
        try sendEditorKey("c", window: window)
        XCTAssertEqual(model.values.selectedID, secondID, "C is ignored while editing is locked")
        model.cancelReverse()
        await model.reverseTask?.value
        XCTAssertFalse(model.editingLocked)

        try sendEditorKey("c", window: window)
        XCTAssertEqual(model.values.selectedID, firstID)
    }
}
