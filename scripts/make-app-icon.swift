// Usage: swift scripts/make-app-icon.swift
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

let canvas: CGFloat = 1024
// Apple's macOS grid: 824 body, 100 margin.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyRadius: CGFloat = 185.4
let bodyShape = continuousRect(body, radius: bodyRadius)
let page = CGRect(x: 200, y: 180, width: 392, height: 516)
let pageFold: CGFloat = 104
let menuPanel = CGRect(x: 396, y: 452, width: 456, height: 392)
let pointSizes = [16, 32, 128, 256, 512]

// Template glyphs use an 18-unit, y-down design box.
let glyphBox: CGFloat = 18
let glyphPage = CGRect(x: 2.6, y: 1.4, width: 9.8, height: 15.2)
let glyphFold: CGFloat = 3.4
let glyphRows: [(y: CGFloat, length: CGFloat)] = [(7.4, 4.6), (10.6, 4.6), (13.8, 3.2)]
let glyphRowLeft = glyphPage.minX + 2.5
let dimAlpha: CGFloat = 0.32
let clearanceGap: CGFloat = 1.0
let menuBarPoints: CGFloat = 18
let menuBarWeight: CGFloat = 1.5
let finderPoints: CGFloat = 16
// Renders near 1.47 pt, matching the menu bar weight.
let finderWeight: CGFloat = 1.65

let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let catalog = repository.appending(path: "App/Resources/Assets.xcassets")
let iconSet = catalog.appending(path: "AppIcon.appiconset")
let finderCatalog = repository.appending(path: "FinderSync/Assets.xcassets")

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat(hex >> 16 & 0xFF) / 255,
        green: CGFloat(hex >> 8 & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha)
}

func continuousRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
}

func capsule(_ rect: CGRect) -> CGPath {
    let radius = min(rect.width, rect.height) / 2
    return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func circle(_ center: CGPoint, _ radius: CGFloat) -> CGPath {
    CGPath(
        ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2),
        transform: nil)
}

func polyline(_ points: [CGPoint], closed: Bool = false) -> CGPath {
    let path = CGMutablePath()
    path.addLines(between: points)
    if closed { path.closeSubpath() }
    return path
}

func stroked(_ path: CGPath, _ width: CGFloat) -> CGPath {
    path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 4)
}

func fillVertical(_ context: CGContext, _ path: CGPath, _ colors: [CGColor], from top: CGFloat, to bottom: CGFloat) {
    guard let gradient = CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: nil) else {
        fatalError("Gradient creation failed")
    }
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(
        gradient, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

// Shadows ignore the CTM; scale them manually.
func withShadow(
    _ context: CGContext, scale: CGFloat, drop: CGFloat, blur: CGFloat, color: CGColor, _ draw: () -> Void
) {
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -drop * scale), blur: blur * scale, color: color)
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    draw()
    context.endTransparencyLayer()
    context.restoreGState()
}

func foldedPage(_ rect: CGRect, fold: CGFloat, radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: rect.minX, y: rect.midY))
    path.addArc(
        tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY),
        radius: radius)
    path.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
    path.addArc(
        tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY),
        radius: radius)
    path.addArc(
        tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.minY),
        radius: radius)
    path.closeSubpath()
    return path
}

func foldCorner(_ rect: CGRect, fold: CGFloat) -> [CGPoint] {
    [
        CGPoint(x: rect.maxX - fold, y: rect.minY), CGPoint(x: rect.maxX - fold, y: rect.minY + fold),
        CGPoint(x: rect.maxX, y: rect.minY + fold),
    ]
}

func drawBackground(_ context: CGContext, scale: CGFloat) {
    let colors: [UInt32] = [0x6CC0FF, 0x2F7DF0, 0x1A4FC8]
    withShadow(context, scale: scale, drop: 10, blur: 22, color: srgb(0x000000, 0.32)) {
        context.addPath(bodyShape)
        context.setFillColor(srgb(colors[0]))
        context.fillPath()
    }
    fillVertical(context, bodyShape, colors.map { srgb($0) }, from: body.minY, to: body.maxY)
    guard
        let glow = CGGradient(
            colorsSpace: nil, colors: [srgb(0xFFFFFF, 0.22), srgb(0xFFFFFF, 0)] as CFArray, locations: nil)
    else { fatalError("Gradient creation failed") }
    context.saveGState()
    context.addPath(bodyShape)
    context.clip()
    context.drawRadialGradient(
        glow, startCenter: CGPoint(x: 330, y: 150), startRadius: 0, endCenter: CGPoint(x: 330, y: 150),
        endRadius: 640, options: [])
    fillVertical(
        context, stroked(bodyShape, 7), [srgb(0xFFFFFF, 0.55), srgb(0xFFFFFF, 0.055)], from: body.minY,
        to: body.midY)
    context.restoreGState()
}

func documentLines(in rect: CGRect, count: Int, thickness: CGFloat, color: CGColor, on context: CGContext) {
    let pitch = rect.height / CGFloat(count)
    for index in 0..<count {
        let width = rect.width * (index == count - 1 ? 0.62 : 1)
        let top = rect.minY + pitch * CGFloat(index) + (pitch - thickness) / 2
        context.addPath(capsule(CGRect(x: rect.minX, y: top, width: width, height: thickness)))
    }
    context.setFillColor(color)
    context.fillPath()
}

func drawPage(_ context: CGContext, scale: CGFloat, detailed: Bool) {
    let shape = foldedPage(page, fold: pageFold, radius: 34)
    withShadow(context, scale: scale, drop: 12, blur: 28, color: srgb(0x0A2A6E, 0.35)) {
        fillVertical(context, shape, [srgb(0xFFFFFF), srgb(0xE8F0FC)], from: page.minY, to: page.maxY)
    }
    context.addPath(polyline(foldCorner(page, fold: pageFold), closed: true))
    context.setFillColor(srgb(0xC4D7F4))
    context.fillPath()
    if detailed {
        documentLines(
            in: CGRect(x: 262, y: 320, width: 250, height: 200), count: 4, thickness: 22, color: srgb(0xC6D5EC),
            on: context)
    }
}

func drawMenu(_ context: CGContext, scale: CGFloat, detailed: Bool) {
    let shape = continuousRect(menuPanel, radius: 64)
    withShadow(context, scale: scale, drop: 22, blur: 48, color: srgb(0x061C52, 0.5)) {
        fillVertical(
            context, shape, [srgb(0xFFFFFF, 0.97), srgb(0xEEF3FB, 0.97)], from: menuPanel.minY, to: menuPanel.maxY)
    }
    let rowCenters = [menuPanel.minY + 92, menuPanel.midY, menuPanel.maxY - 92]
    for (index, centerY) in rowCenters.enumerated() {
        if index == 1 {
            drawHighlightedRow(context, centerY: centerY, detailed: detailed)
        } else if detailed {
            let width: CGFloat = index == 0 ? 250 : 190
            context.addPath(capsule(CGRect(x: menuPanel.minX + 70, y: centerY - 15, width: width, height: 30)))
            context.setFillColor(srgb(0xBCCBE0))
            context.fillPath()
        }
    }
}

func drawHighlightedRow(_ context: CGContext, centerY: CGFloat, detailed: Bool) {
    let pill = CGRect(x: menuPanel.minX + 26, y: centerY - 56, width: menuPanel.width - 52, height: 112)
    fillVertical(
        context, continuousRect(pill, radius: 36), [srgb(0x4FA2FF), srgb(0x1F66EE)], from: pill.minY, to: pill.maxY)
    let labelHeight: CGFloat = detailed ? 30 : 44
    let labelWidth: CGFloat = detailed ? 200 : 240
    context.addPath(
        capsule(CGRect(x: pill.minX + 44, y: centerY - labelHeight / 2, width: labelWidth, height: labelHeight)))
    let chevronX = pill.maxX - 56
    let chevron = polyline([
        CGPoint(x: chevronX - 18, y: centerY - 28), CGPoint(x: chevronX + 10, y: centerY),
        CGPoint(x: chevronX - 18, y: centerY + 28),
    ])
    context.addPath(stroked(chevron, detailed ? 18 : 26))
    context.setFillColor(srgb(0xFFFFFF))
    context.fillPath()
}

func drawPointer(_ context: CGContext, scale: CGFloat) {
    let tip = CGPoint(x: menuPanel.minX - 6, y: menuPanel.minY - 30)
    let unit: CGFloat = 150.0 / 122
    let outline: [(CGFloat, CGFloat)] = [(0, 0), (0, 104), (26, 80), (44, 122), (62, 114), (44, 74), (78, 74)]
    let pointer = polyline(outline.map { CGPoint(x: tip.x + $0.0 * unit, y: tip.y + $0.1 * unit) }, closed: true)
    withShadow(context, scale: scale, drop: 6, blur: 12, color: srgb(0x000000, 0.35)) {
        context.addPath(stroked(pointer, 18))
        context.setFillColor(srgb(0xFFFFFF))
        context.fillPath()
        context.addPath(pointer)
        context.setFillColor(srgb(0x111114))
        context.fillPath()
    }
}

func renderIcon(pixels: Int) -> CGImage {
    guard
        let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("Bitmap context creation failed") }
    let scale = CGFloat(pixels) / canvas
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: scale, y: -scale)
    // Fine details blur together below 64 px.
    let detailed = pixels >= 64
    drawBackground(context, scale: scale)
    drawPage(context, scale: scale, detailed: detailed)
    drawMenu(context, scale: scale, detailed: detailed)
    if detailed { drawPointer(context, scale: scale) }
    guard let image = context.makeImage() else { fatalError("Image creation failed") }
    return image
}

enum GlyphState {
    case idle, busy(Int), busyStatic, attention
}

struct GlyphLayer {
    let alpha: CGFloat
    let shape: CGPath
}

func layer(_ alpha: CGFloat, _ shapes: [CGPath]) -> GlyphLayer {
    GlyphLayer(alpha: alpha, shape: shapes.dropFirst().reduce(shapes[0]) { $0.union($1) })
}

func knockout(_ layers: [GlyphLayer], _ hole: CGPath) -> [GlyphLayer] {
    layers.map { GlyphLayer(alpha: $0.alpha, shape: $0.shape.subtracting(hole)) }
}

func attentionBadge(at center: CGPoint, radius: CGFloat) -> (shape: CGPath, clearance: CGPath) {
    let stemWidth = radius * 0.4
    let stem = capsule(
        CGRect(x: center.x - stemWidth / 2, y: center.y - radius * 0.66, width: stemWidth, height: radius * 0.76))
    let dot = circle(CGPoint(x: center.x, y: center.y + radius * 0.48), stemWidth * 0.55)
    return (circle(center, radius).subtracting(stem.union(dot)), circle(center, radius + clearanceGap))
}

func selectedRow(_ row: Int) -> (shape: CGPath, clearance: CGPath) {
    let left = glyphRowLeft - 1.1
    let bar = CGRect(x: left, y: glyphRows[row].y - 1.75, width: 17.4 - left, height: 3.5)
    return (capsule(bar), capsule(bar.insetBy(dx: -clearanceGap, dy: -clearanceGap)))
}

// The highlighted menu row slides out past the page edge.
func glyphLayers(_ state: GlyphState, weight: CGFloat) -> [GlyphLayer] {
    let outline = stroked(foldedPage(glyphPage, fold: glyphFold, radius: 1.3), weight)
    let fold = stroked(polyline(foldCorner(glyphPage, fold: glyphFold)), weight * 0.85)
    let rows = glyphRows.map {
        stroked(polyline([CGPoint(x: glyphRowLeft, y: $0.y), CGPoint(x: glyphRowLeft + $0.length, y: $0.y)]), weight)
    }
    switch state {
    case .idle, .busy:
        let row = if case .busy(let frame) = state { frame } else { 1 }
        let picked = selectedRow(row)
        let others = rows.indices.filter { $0 != row }.map { rows[$0] }
        return knockout([layer(1, [outline, fold] + others)], picked.clearance) + [layer(1, [picked.shape])]
    case .busyStatic:
        let dots = (0..<3).map {
            circle(CGPoint(x: glyphRowLeft + 0.4 + CGFloat($0) * 2.3, y: glyphRows[1].y), weight * 0.75)
        }
        return [layer(dimAlpha, [rows[0], rows[2]]), layer(1, [outline, fold] + dots)]
    case .attention:
        let badge = attentionBadge(at: CGPoint(x: 13.9, y: 13.9), radius: 3.7)
        return knockout([layer(1, [outline, fold] + rows)], badge.clearance) + [layer(1, [badge.shape])]
    }
}

func writeTemplatePDF(_ state: GlyphState, points: CGFloat, weight: CGFloat, to url: URL) {
    var box = CGRect(x: 0, y: 0, width: points, height: points)
    guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { fatalError("Cannot create \(url.path)") }
    context.beginPDFPage(nil)
    context.translateBy(x: 0, y: points)
    context.scaleBy(x: points / glyphBox, y: -points / glyphBox)
    for glyphLayer in glyphLayers(state, weight: weight) {
        context.addPath(glyphLayer.shape)
        context.setFillColor(srgb(0x000000, glyphLayer.alpha))
        context.fillPath()
    }
    context.endPDFPage()
    context.closePDF()
}

func writePNG(_ image: CGImage, to url: URL) {
    guard
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("Cannot create \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write \(url.path)") }
}

struct IconSlot: Encodable {
    let filename: String
    let idiom = "mac"
    let scale: String
    let size: String
}

struct CatalogInfo: Encodable {
    let author = "xcode"
    let version = 1
}

struct IconSetContents: Encodable {
    let images: [IconSlot]
    let info = CatalogInfo()
}

struct CatalogContents: Encodable {
    let info = CatalogInfo()
}

struct VectorImage: Encodable {
    let filename: String
    let idiom = "universal"
}

struct TemplateProperties: Encodable {
    let preservesVector = true
    let renderingIntent = "template"

    enum CodingKeys: String, CodingKey {
        case preservesVector = "preserves-vector-representation"
        case renderingIntent = "template-rendering-intent"
    }
}

struct TemplateSetContents: Encodable {
    let images: [VectorImage]
    let info = CatalogInfo()
    let properties = TemplateProperties()
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let newline = Data("\n".utf8)

func writeJSON(_ value: some Encodable, to url: URL) throws {
    try (encoder.encode(value) + newline).write(to: url)
}

func writeTemplateSet(
    _ name: String, state: GlyphState, points: CGFloat, weight: CGFloat, in assetCatalog: URL
) throws {
    let imageSet = assetCatalog.appending(path: "\(name).imageset")
    try FileManager.default.createDirectory(at: imageSet, withIntermediateDirectories: true)
    let filename = "\(name).pdf"
    writeTemplatePDF(state, points: points, weight: weight, to: imageSet.appending(path: filename))
    try writeJSON(
        TemplateSetContents(images: [VectorImage(filename: filename)]), to: imageSet.appending(path: "Contents.json"))
}

try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)
var slots: [IconSlot] = []
for points in pointSizes {
    for factor in [1, 2] {
        let filename = "icon_\(points)x\(points)\(factor == 2 ? "@2x" : "").png"
        writePNG(renderIcon(pixels: points * factor), to: iconSet.appending(path: filename))
        slots.append(IconSlot(filename: filename, scale: "\(factor)x", size: "\(points)x\(points)"))
    }
}
try writeJSON(IconSetContents(images: slots), to: iconSet.appending(path: "Contents.json"))
try writeJSON(CatalogContents(), to: catalog.appending(path: "Contents.json"))

let statusGlyphs: [(String, GlyphState)] = [
    ("StatusIdle", .idle), ("StatusBusy1", .busy(0)), ("StatusBusy2", .busy(1)), ("StatusBusy3", .busy(2)),
    ("StatusBusyStatic", .busyStatic), ("StatusAttention", .attention),
]
for (name, state) in statusGlyphs {
    try writeTemplateSet(name, state: state, points: menuBarPoints, weight: menuBarWeight, in: catalog)
}
try FileManager.default.createDirectory(at: finderCatalog, withIntermediateDirectories: true)
try writeJSON(CatalogContents(), to: finderCatalog.appending(path: "Contents.json"))
try writeTemplateSet("FinderRoot", state: .idle, points: finderPoints, weight: finderWeight, in: finderCatalog)
print("Wrote \(slots.count) icons and \(statusGlyphs.count + 1) template glyphs")
