import AppKit
import ImageIO
import SwiftUI
import VisionKit
import os

struct PreviewZoom: Equatable {
    enum Preset: Equatable {
        case fit, actualSize
    }

    let preset: Preset?
    // Relative to the image's own pixels.
    let percent: Double
}

@MainActor
@Observable
final class PreviewImageModel {
    enum Phase {
        case loading, ready(PreviewImageOpened), failed
    }

    // Avoids a redundant decode for rounding noise.
    private static let detailTolerance = 1.01
    private(set) var phase = Phase.loading
    private(set) var detail: CGImage?
    private(set) var detailFailed = false
    private(set) var animator: PreviewImageAnimator?
    private(set) var zoom = PreviewZoom(preset: .fit, percent: 100)
    let liveText = PreviewLiveText()
    private let source = PreviewImageSource()
    private var detailWork: Task<Void, Never>?
    private var windowVisible = true

    var opened: PreviewImageOpened? {
        if case .ready(let opened) = phase { opened } else { nil }
    }

    var image: CGImage? { animator?.frame ?? detail ?? opened?.first }

    private var canDecodeFullResolution: Bool { opened?.offersFullResolution == true && !detailFailed }

    // Zoomed past the decode with nothing sharper.
    var showsReduced: Bool {
        guard let opened, detail == nil, !canDecodeFullResolution else { return false }
        return needsDetail(opened)
    }

    var reducedSize: CGSize? {
        guard let opened, detail == nil, !canDecodeFullResolution, opened.decodedScale < 1 else { return nil }
        return CGSize(width: opened.first.width, height: opened.first.height)
    }

    func load(_ url: URL, reduceMotion: Bool) async {
        do {
            let opened = try await source.open(url)
            try Task.checkCancellation()
            phase = .ready(opened)
            if let timing = opened.animation {
                let animator = PreviewImageAnimator(source: source, first: opened.first, timing: timing)
                animator.setWindowVisible(windowVisible)
                self.animator = animator
                if !reduceMotion { animator.play() }
            } else if PreviewLiveText.isWorthAnalyzing(pixelSize: opened.pixelSize, animated: false) {
                liveText.analyze(opened.first)
            }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed
            Logger(category: "finder-preview").error(
                "Preview image failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    func setWindowVisible(_ visible: Bool) {
        windowVisible = visible
        animator?.setWindowVisible(visible)
    }

    func zoomChanged(_ zoom: PreviewZoom) {
        self.zoom = zoom
        guard let opened, canDecodeFullResolution, detail == nil, detailWork == nil, needsDetail(opened) else {
            return
        }
        detailWork = Task { [weak self, source] in
            do {
                let detail = try await source.fullResolution()
                try Task.checkCancellation()
                self?.detail = detail
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                detailFailed = true
                Logger(category: "finder-preview").error(
                    "Full-resolution image failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    func stop() {
        animator?.pause()
        liveText.cancel()
        detailWork?.cancel()
    }

    private func needsDetail(_ opened: PreviewImageOpened) -> Bool {
        opened.decodedScale < 1 && zoom.percent / 100 > opened.decodedScale * Self.detailTolerance
    }
}

struct PreviewImageViewer: View {
    let url: URL
    @State private var model = PreviewImageModel()
    @State private var zoomRequest = PreviewZoomRequest(preset: .fit, serial: 0)
    @State private var showsInfo = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.previewSelectionPending) private var selectionPending

    var body: some View {
        VStack(spacing: 0) {
            PreviewToolbar {
                if let opened = model.opened {
                    ViewThatFits(in: .horizontal) {
                        controls(opened, iconsOnly: false, showsStatus: true)
                        controls(opened, iconsOnly: true, showsStatus: true)
                        controls(opened, iconsOnly: true, showsStatus: false)
                    }
                }
            }
            Group {
                switch model.phase {
                case .failed: PreviewFailure()
                case .ready(let opened):
                    if let image = model.image {
                        PreviewImageCanvas(
                            image: image, opened: opened, analysis: model.liveText.analysis, request: zoomRequest,
                            zoomChanged: model.zoomChanged, occlusionChanged: model.setWindowVisible)
                    }
                case .loading: ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
        }
        .task { await model.load(url, reduceMotion: reduceMotion) }
        .onChange(of: selectionPending) { _, pending in
            if pending { model.liveText.cancel() }
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { model.animator?.pause() }
        }
        .onDisappear { model.stop() }
    }

    private func controls(_ opened: PreviewImageOpened, iconsOnly: Bool, showsStatus: Bool) -> some View {
        HStack(spacing: 8) {
            ControlGroup {
                zoomToggle(
                    .fit, title: Text("Fit"), symbol: "arrow.up.left.and.down.right.magnifyingglass",
                    iconsOnly: iconsOnly)
                zoomToggle(.actualSize, title: Text("100%"), symbol: "1.magnifyingglass", iconsOnly: iconsOnly)
            }
            .fixedSize()
            .help(Text("Fit shows the whole image and 100% shows actual pixels. Double-click the image to switch."))
            if showsStatus { status }
            if let animator = model.animator { playButton(animator) }
            Button {
                showsInfo.toggle()
            } label: {
                Image(systemName: "info.circle")
            }
            .help(Text("Image Info"))
            .accessibilityLabel(Text("Image Info"))
            .popover(isPresented: $showsInfo, arrowEdge: .bottom) {
                PreviewImageInfoView(metadata: opened.metadata, reducedSize: model.reducedSize)
            }
        }
        .fixedSize()
    }

    private func zoomToggle(_ preset: PreviewZoom.Preset, title: Text, symbol: String, iconsOnly: Bool) -> some View {
        Toggle(
            isOn: Binding(
                get: { model.zoom.preset == preset },
                set: { if $0 { zoomRequest = PreviewZoomRequest(preset: preset, serial: zoomRequest.serial + 1) } })
        ) {
            if iconsOnly { Image(systemName: symbol).accessibilityLabel(title) } else { title }
        }
        .toggleStyle(.button)
        .accessibilityValue(model.zoom.preset == nil ? Text(zoomPercent) : Text(verbatim: ""))
    }

    @ViewBuilder private var status: some View {
        if model.showsReduced {
            Text("Reduced").foregroundStyle(.secondary)
                .help(Text("This image is shown at a reduced size. Open it in Preview to see every pixel."))
        } else if model.zoom.preset == nil {
            Text(zoomPercent).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private var zoomPercent: String {
        (model.zoom.percent / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    private func playButton(_ animator: PreviewImageAnimator) -> some View {
        Button {
            if animator.isPlaying { animator.pause() } else { animator.play() }
        } label: {
            Image(systemName: animator.isPlaying ? "pause.fill" : "play.fill")
        }
        .keyboardShortcut(.space, modifiers: [])
        .help(animator.isPlaying ? Text("Pause (Space)") : Text("Play (Space)"))
        .accessibilityLabel(animator.isPlaying ? Text("Pause") : Text("Play"))
    }
}

struct PreviewZoomRequest: Equatable {
    let preset: PreviewZoom.Preset
    let serial: Int
}

private struct PreviewImageCanvas: NSViewRepresentable {
    let image: CGImage
    let opened: PreviewImageOpened
    let analysis: ImageAnalysis?
    let request: PreviewZoomRequest
    let zoomChanged: (PreviewZoom) -> Void
    let occlusionChanged: (Bool) -> Void

    final class Coordinator {
        var overlay: PreviewLiveTextOverlay?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PreviewImageScroll {
        let scroll = PreviewImageScroll(pixelSize: opened.pixelSize)
        scroll.content.showsCheckerboard = opened.hasAlpha
        scroll.handledRequest = request
        scroll.occlusionChanged = occlusionChanged
        return scroll
    }

    func updateNSView(_ scroll: PreviewImageScroll, context: Context) {
        scroll.zoomChanged = zoomChanged
        scroll.occlusionChanged = occlusionChanged
        scroll.content.image = image
        if let analysis, analysis.hasResults(for: .text) {
            let overlay = context.coordinator.overlay ?? PreviewLiveTextOverlay(content: scroll.content)
            context.coordinator.overlay = overlay
            scroll.liveText = overlay.view
            overlay.show(analysis)
        } else {
            context.coordinator.overlay?.show(nil)
        }
        if scroll.handledRequest != request {
            scroll.handledRequest = request
            scroll.setZoom(request.preset, animated: !context.environment.accessibilityReduceMotion)
        }
    }
}

final class PreviewImageScroll: NSScrollView, NSGestureRecognizerDelegate {
    private static let minimumZoom: CGFloat = 0.01
    private static let maximumZoom: CGFloat = 16
    private static let actualSizeTolerance = 0.5
    private static let zoomDuration: TimeInterval = 0.15
    private static let easeOut = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
    let content: PreviewImageLayerView
    var zoomChanged: ((PreviewZoom) -> Void)?
    var occlusionChanged: ((Bool) -> Void)?
    var handledRequest: PreviewZoomRequest?
    weak var liveText: ImageAnalysisOverlayView?
    // Legacy scrollers would shrink the fit.
    private(set) var fitting = true {
        didSet {
            hasVerticalScroller = !fitting
            hasHorizontalScroller = !fitting
        }
    }
    private var reported: PreviewZoom?
    private var reportedWindowVisible: Bool?
    // Intermediate animation steps keep the target's readout.
    private var zooming = false

    override var magnification: CGFloat {
        didSet { if !zooming { report(magnification) } }
    }

    init(pixelSize: CGSize) {
        content = PreviewImageLayerView(frame: NSRect(origin: .zero, size: pixelSize))
        super.init(frame: .zero)
        contentView = CenteringClipView()
        autohidesScrollers = true
        drawsBackground = false
        allowsMagnification = true
        minMagnification = Self.minimumZoom
        maxMagnification = Self.maximumZoom
        documentView = content
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(doubleClicked(_:)))
        doubleClick.numberOfClicksRequired = 2
        doubleClick.delegate = self
        content.addGestureRecognizer(doubleClick)
    }

    required init?(coder: NSCoder) { nil }

    var zoom: PreviewZoom { zoom(at: magnification) }

    func setZoom(_ preset: PreviewZoom.Preset, centeredAt point: NSPoint? = nil, animated: Bool) {
        fitting = preset == .fit
        let target = clamped(preset == .fit ? fitMagnification : 1 / backingScale)
        let center = point ?? NSPoint(x: documentVisibleRect.midX, y: documentVisibleRect.midY)
        zooming = true
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.zoomDuration
                context.timingFunction = Self.easeOut
                animator().setMagnification(target, centeredAt: center)
            } completionHandler: {
                MainActor.assumeIsolated { self.zooming = false }
            }
        } else {
            setMagnification(target, centeredAt: center)
            zooming = false
        }
        report(target)
    }

    func toggleZoom(at point: NSPoint, animated: Bool) {
        setZoom(fitting ? .actualSize : .fit, centeredAt: point, animated: animated)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            reportWindowVisibility(false, deferred: true)
            return
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(occlusionDidChange),
            name: NSWindow.didChangeOcclusionStateNotification, object: window)
        reportWindowVisibility(window.occlusionState.contains(.visible), deferred: true)
    }

    @objc private func occlusionDidChange() {
        guard let window else { return }
        reportWindowVisibility(window.occlusionState.contains(.visible), deferred: false)
    }

    private func reportWindowVisibility(_ visible: Bool, deferred: Bool) {
        guard visible != reportedWindowVisible else { return }
        reportedWindowVisible = visible
        if deferred {
            Task { @MainActor [weak self] in self?.occlusionChanged?(visible) }
        } else {
            occlusionChanged?(visible)
        }
    }

    override func layout() {
        super.layout()
        guard fitting else { return }
        let target = clamped(fitMagnification)
        if abs(magnification - target) > 0.001 { magnification = target }
        report(target)
    }

    override func magnify(with event: NSEvent) {
        fitting = false
        super.magnify(with: event)
        report(magnification)
    }

    override func smartMagnify(with event: NSEvent) {
        toggleZoom(at: content.convert(event.locationInWindow, from: nil), animated: Self.animates)
    }

    @objc private func doubleClicked(_ recognizer: NSClickGestureRecognizer) {
        toggleZoom(at: recognizer.location(in: content), animated: Self.animates)
    }

    // Double-clicking text selects a word instead.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
        guard let liveText, liveText.analysis != nil else { return true }
        return !liveText.hasInteractiveItem(at: gestureRecognizer.location(in: liveText))
    }

    private static var animates: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? 1 }

    private var fitMagnification: CGFloat {
        guard content.frame.width > 0, content.frame.height > 0 else { return 1 }
        return min(contentSize.width / content.frame.width, contentSize.height / content.frame.height)
    }

    private func clamped(_ value: CGFloat) -> CGFloat { min(maxMagnification, max(minMagnification, value)) }

    private func zoom(at magnification: CGFloat) -> PreviewZoom {
        let percent = magnification * backingScale * 100
        if fitting { return PreviewZoom(preset: .fit, percent: percent) }
        return PreviewZoom(preset: abs(percent - 100) < Self.actualSizeTolerance ? .actualSize : nil, percent: percent)
    }

    private func report(_ magnification: CGFloat) {
        content.checkerScale = magnification
        let zoom = zoom(at: magnification)
        guard zoom != reported else { return }
        reported = zoom
        // Layout can run inside a SwiftUI update.
        Task { @MainActor [weak self] in self?.zoomChanged?(zoom) }
    }

    final class CenteringClipView: NSClipView {
        override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
            var bounds = super.constrainBoundsRect(proposedBounds)
            guard let documentView else { return bounds }
            let content = documentView.frame
            if bounds.width > content.width { bounds.origin.x = (content.width - bounds.width) / 2 }
            if bounds.height > content.height { bounds.origin.y = (content.height - bounds.height) / 2 }
            return bounds
        }
    }
}

final class PreviewImageLayerView: NSView {
    struct CheckerKey: Hashable {
        let appearance: NSAppearance.Name
        let squarePoints: Int
    }

    // On-screen size of one checkerboard square.
    static let checkerSquarePoints: CGFloat = 8
    static let minimumCheckerSquarePoints: CGFloat = 2
    static let maximumCheckerSquarePoints: CGFloat = 64
    private static let supportedAppearances: [NSAppearance.Name] = [
        .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
    ]
    private static var checkerCache: [CheckerKey: CGColor] = [:]

    var image: CGImage? {
        didSet {
            guard image !== oldValue, let layer else { return }
            layer.contents = image
            layer.preferredDynamicRange = (image?.contentHeadroom ?? 0) > 1 ? .constrainedHigh : .standard
        }
    }

    var showsCheckerboard = false {
        didSet { needsDisplay = true }
    }

    var checkerScale: CGFloat = 1 {
        didSet {
            guard showsCheckerboard else { return }
            let square = Self.checkerSquarePoints(forScale: checkerScale)
            if square != currentCheckerSquare { needsDisplay = true }
        }
    }

    private var currentCheckerSquare: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(String(localized: "Image Preview"))
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.contentsGravity = .resize
        guard showsCheckerboard else {
            currentCheckerSquare = nil
            layer?.backgroundColor = nil
            return
        }
        let square = Self.checkerSquarePoints(forScale: checkerScale)
        currentCheckerSquare = square
        layer?.backgroundColor = Self.checkerboardColor(for: checkerAppearanceName, squarePoints: square)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // Quantized and bounded to keep tiles small.
    static func checkerSquarePoints(forScale scale: CGFloat) -> Int {
        let raw = checkerSquarePoints / max(scale, .ulpOfOne)
        let clamped = min(max(raw, minimumCheckerSquarePoints), maximumCheckerSquarePoints)
        let power = pow(2.0, round(log2(Double(clamped))))
        return min(max(Int(power), Int(minimumCheckerSquarePoints)), Int(maximumCheckerSquarePoints))
    }

    static func checkerboardColor(for appearance: NSAppearance.Name, squarePoints: Int) -> CGColor {
        let clampedSquare = min(
            max(squarePoints, Int(minimumCheckerSquarePoints)), Int(maximumCheckerSquarePoints))
        let key = CheckerKey(appearance: appearance, squarePoints: clampedSquare)
        if let cached = checkerCache[key] { return cached }
        let color = makeCheckerboardColor(for: appearance, squarePoints: clampedSquare)
        checkerCache[key] = color
        return color
    }

    private static func makeCheckerboardColor(for appearance: NSAppearance.Name, squarePoints: Int) -> CGColor {
        let (light, dark) = checkerShades(for: appearance)
        let tileEdge = squarePoints * 2
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: nil, width: tileEdge, height: tileEdge, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return NSColor(white: light, alpha: 1).cgColor }
        context.setFillColor(CGColor(gray: light, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: tileEdge, height: tileEdge))
        context.setFillColor(CGColor(gray: dark, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: squarePoints, height: squarePoints))
        context.fill(CGRect(x: squarePoints, y: squarePoints, width: squarePoints, height: squarePoints))
        guard let tileImage = context.makeImage() else { return NSColor(white: light, alpha: 1).cgColor }
        let pattern = NSImage(cgImage: tileImage, size: NSSize(width: tileEdge, height: tileEdge))
        return NSColor(patternImage: pattern).cgColor
    }

    private var checkerAppearanceName: NSAppearance.Name {
        effectiveAppearance.bestMatch(from: Self.supportedAppearances) ?? .aqua
    }

    private static func checkerShades(for appearance: NSAppearance.Name) -> (CGFloat, CGFloat) {
        switch appearance {
        case .darkAqua: (0.17, 0.23)
        case .accessibilityHighContrastAqua: (1, 0.78)
        case .accessibilityHighContrastDarkAqua: (0.1, 0.32)
        default: (1, 0.9)
        }
    }
}
