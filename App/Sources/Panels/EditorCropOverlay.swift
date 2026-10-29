import Engine
import SwiftUI

extension MediaEditorModel {
    var resolvedCropAspect: Double? {
        guard cropAspect != 0, sourceSize.width > 0, sourceSize.height > 0 else { return nil }
        let canvas = values.photo.geometry.canvasSize(sourceSize)
        let ratio = cropAspect == -1 ? canvas.width / canvas.height : cropAspect
        return cropPortrait ? 1 / ratio : ratio
    }

    func synchronizeCropAspect() {
        guard let expected = resolvedCropAspect else { return }
        let canvas = values.photo.geometry.canvasSize(sourceSize)
        let crop = values.photo.geometry.crop
        let actual = crop.width * canvas.width / (crop.height * canvas.height)
        let tolerance = 0.0001
        if abs(actual / expected - 1) < tolerance { return }
        if abs(actual * expected - 1) < tolerance { cropPortrait.toggle() } else { cropAspect = 0 }
    }

    func setCropPercentage(_ percent: Double, keyPath: WritableKeyPath<EditCrop, Double>) {
        guard percent.isFinite else { return }
        var crop = values.photo.geometry.crop
        let amount = percent / 100
        switch keyPath {
        case \.x: crop.x = min(max(0, amount), 1 - crop.width)
        case \.y: crop.y = min(max(0, amount), 1 - crop.height)
        default:
            let canvas = values.photo.geometry.canvasSize(sourceSize)
            let ratio = resolvedCropAspect.map { $0 * canvas.height / canvas.width }
            if keyPath == \.width {
                crop.width = min(max(0.02, amount), 1 - crop.x)
                if let ratio { crop.height = crop.width / ratio }
            } else {
                crop.height = min(max(0.02, amount), 1 - crop.y)
                if let ratio { crop.width = crop.height * ratio }
            }
            let fit = min(1, (1 - crop.x) / crop.width, (1 - crop.y) / crop.height)
            crop.width *= fit
            crop.height *= fit
        }
        change { $0.photo.geometry.crop = crop }
    }

    func fitCropAspect() {
        guard let aspect = resolvedCropAspect else { return }
        let canvas = values.photo.geometry.canvasSize(sourceSize)
        let normalized = aspect * canvas.height / canvas.width
        let width = min(1, normalized)
        let height = min(1, 1 / normalized)
        change {
            $0.photo.geometry.crop = EditCrop(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
        }
    }
}

struct EditorCropOverlay: View {
    @Bindable var model: MediaEditorModel
    @State private var dragStart: EditCrop?
    private let minimumSize = 0.02

    private enum Edge: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
        var left: Bool { [.topLeft, .left, .bottomLeft].contains(self) }
        var right: Bool { [.topRight, .right, .bottomRight].contains(self) }
        var top: Bool { [.topLeft, .top, .topRight].contains(self) }
        var bottom: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }
    }

    var body: some View {
        GeometryReader { proxy in
            let crop = model.values.photo.geometry.crop
            let rect = CGRect(
                x: crop.x * proxy.size.width, y: crop.y * proxy.size.height,
                width: crop.width * proxy.size.width, height: crop.height * proxy.size.height)
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: proxy.size))
                    path.addRect(rect)
                }.fill(.black.opacity(0.45), style: FillStyle(eoFill: true)).allowsHitTesting(false)
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                    .gesture(drag(edge: nil, size: proxy.size))
                    .accessibilityLabel("Crop selection")
                    .accessibilityHint("Use arrow keys to move the selection.")
                    .focusable()
                    .onKeyPress(.leftArrow) {
                        move(x: -0.01, y: 0); return .handled
                    }
                    .onKeyPress(.rightArrow) {
                        move(x: 0.01, y: 0); return .handled
                    }
                    .onKeyPress(.upArrow) {
                        move(x: 0, y: -0.01); return .handled
                    }
                    .onKeyPress(.downArrow) {
                        move(x: 0, y: 0.01); return .handled
                    }
                Path { path in
                    path.addRect(rect)
                    for fraction in [1.0 / 3, 2.0 / 3] {
                        path.move(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY))
                        path.addLine(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY))
                        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * fraction))
                        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * fraction))
                    }
                }.stroke(.white.opacity(0.85), lineWidth: 1).allowsHitTesting(false)
                ForEach(Edge.allCases, id: \.self) { edge in
                    let x = edge.left ? rect.minX : edge.right ? rect.maxX : rect.midX
                    let y = edge.top ? rect.minY : edge.bottom ? rect.maxY : rect.midY
                    RoundedRectangle(cornerRadius: 2).fill(.white)
                        .frame(width: edge.left || edge.right ? 5 : 22, height: edge.top || edge.bottom ? 5 : 22)
                        .shadow(color: .black.opacity(0.6), radius: 1)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                        .position(x: x, y: y).gesture(drag(edge: edge, size: proxy.size))
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func move(x: Double, y: Double) {
        model.change {
            var crop = $0.photo.geometry.crop
            crop.x = min(max(0, crop.x + x), 1 - crop.width)
            crop.y = min(max(0, crop.y + y), 1 - crop.height)
            $0.photo.geometry.crop = crop
        }
    }

    private func drag(edge: Edge?, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0).onChanged { gesture in
            if dragStart == nil { dragStart = model.values.photo.geometry.crop; model.beginInteraction() }
            guard let start = dragStart else { return }
            let dx = gesture.translation.width / size.width
            let dy = gesture.translation.height / size.height
            var crop = start
            if let edge {
                var left = start.x
                var right = start.x + start.width
                var top = start.y
                var bottom = start.y + start.height
                if edge.left { left = min(max(0, start.x + dx), right - minimumSize) }
                if edge.right { right = max(min(1, start.x + start.width + dx), left + minimumSize) }
                if edge.top { top = min(max(0, start.y + dy), bottom - minimumSize) }
                if edge.bottom { bottom = max(min(1, start.y + start.height + dy), top + minimumSize) }
                if let aspect = model.resolvedCropAspect {
                    let normalized = aspect * size.height / size.width
                    var width = right - left
                    var height = bottom - top
                    if edge.left || edge.right { height = width / normalized } else { width = height * normalized }
                    let anchorX = edge.left ? start.x + start.width : edge.right ? start.x : start.x + start.width / 2
                    let anchorY = edge.top ? start.y + start.height : edge.bottom ? start.y : start.y + start.height / 2
                    let maxWidth = edge.left ? anchorX : edge.right ? 1 - anchorX : min(anchorX, 1 - anchorX) * 2
                    let maxHeight = edge.top ? anchorY : edge.bottom ? 1 - anchorY : min(anchorY, 1 - anchorY) * 2
                    let fit = min(1, maxWidth / width, maxHeight / height)
                    width *= fit
                    height *= fit
                    left = edge.left ? anchorX - width : edge.right ? anchorX : anchorX - width / 2
                    top = edge.top ? anchorY - height : edge.bottom ? anchorY : anchorY - height / 2
                    right = left + width
                    bottom = top + height
                }
                crop = EditCrop(x: max(0, left), y: max(0, top), width: right - left, height: bottom - top)
            } else {
                crop.x = min(max(0, start.x + dx), 1 - start.width)
                crop.y = min(max(0, start.y + dy), 1 - start.height)
            }
            model.change { $0.photo.geometry.crop = crop }
        }.onEnded { _ in
            dragStart = nil; model.endInteraction()
        }
    }
}
