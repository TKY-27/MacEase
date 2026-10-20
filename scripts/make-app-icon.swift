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
let panel = CGRect(x: 172, y: 340, width: 520, height: 480)
let panelRadius: CGFloat = 76
let rowSpacing: CGFloat = 136
let sparkleCenter = CGPoint(x: 756, y: 252)
let sparkleRadius: CGFloat = 108
let pointSizes = [16, 32, 128, 256, 512]

let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let catalog = repository.appending(path: "App/Resources/Assets.xcassets")
let iconSet = catalog.appending(path: "AppIcon.appiconset")

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
    let radius = rect.height / 2
    return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func sparkle(center: CGPoint, radius: CGFloat) -> CGPath {
    let pinch = radius * 0.14
    let path = CGMutablePath()
    path.move(to: CGPoint(x: center.x, y: center.y - radius))
    for (dx, dy) in [(1.0, -1.0), (1.0, 1.0), (-1.0, 1.0), (-1.0, -1.0)] {
        let tip =
            dx == dy
            ? CGPoint(x: center.x, y: center.y + dy * radius)
            : CGPoint(x: center.x + dx * radius, y: center.y)
        path.addQuadCurve(to: tip, control: CGPoint(x: center.x + dx * pinch, y: center.y + dy * pinch))
    }
    path.closeSubpath()
    return path
}

func fillVertical(_ context: CGContext, _ path: CGPath, _ colors: [CGColor], from top: CGFloat, to bottom: CGFloat) {
    guard let gradient = CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: nil) else {
        fatalError("Gradient creation failed")
    }
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(
        gradient, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom), options: [])
    context.restoreGState()
}

// Shadows ignore the CTM; scale them manually.
func setShadow(_ context: CGContext, scale: CGFloat, drop: CGFloat, blur: CGFloat, color: CGColor) {
    context.setShadow(offset: CGSize(width: 0, height: -drop * scale), blur: blur * scale, color: color)
}

func drawBackground(_ context: CGContext, scale: CGFloat) {
    let shape = continuousRect(body, radius: bodyRadius)
    context.saveGState()
    setShadow(context, scale: scale, drop: 10, blur: 20, color: srgb(0x000000, 0.3))
    context.addPath(shape)
    context.setFillColor(srgb(0x2A6FE3))
    context.fillPath()
    context.restoreGState()

    fillVertical(context, shape, [srgb(0x6BBEFF), srgb(0x2C78EC), srgb(0x1B4FC4)], from: body.minY, to: body.maxY)

    let glow = CGGradient(
        colorsSpace: nil, colors: [srgb(0xFFFFFF, 0.28), srgb(0xFFFFFF, 0)] as CFArray, locations: nil)
    guard let glow else { fatalError("Gradient creation failed") }
    context.saveGState()
    context.addPath(shape)
    context.clip()
    context.drawRadialGradient(
        glow, startCenter: CGPoint(x: 300, y: 160), startRadius: 0,
        endCenter: CGPoint(x: 300, y: 160), endRadius: 620, options: [])
    context.restoreGState()

    let rim = shape.copy(strokingWithWidth: 6, lineCap: .round, lineJoin: .round, miterLimit: 1)
    context.saveGState()
    context.addPath(shape)
    context.clip()
    fillVertical(context, rim, [srgb(0xFFFFFF, 0.55), srgb(0xFFFFFF, 0.06)], from: body.minY, to: body.midY)
    context.restoreGState()
}

func drawMenu(_ context: CGContext, scale: CGFloat, detailed: Bool) {
    let shape = continuousRect(panel, radius: panelRadius)
    context.saveGState()
    setShadow(context, scale: scale, drop: 20, blur: 44, color: srgb(0x0A2A6E, 0.42))
    context.addPath(shape)
    context.setFillColor(srgb(0xFFFFFF))
    context.fillPath()
    context.restoreGState()
    fillVertical(context, shape, [srgb(0xFFFFFF), srgb(0xE4EEFC)], from: panel.minY, to: panel.maxY)

    let inset: CGFloat = 26
    let glyphX = panel.minX + 58
    let barHeight: CGFloat = detailed ? 30 : 44
    let barLengths: [CGFloat] = [250, 0, 196]
    for row in 0..<3 {
        let centerY = panel.minY + 104 + CGFloat(row) * rowSpacing
        let highlighted = row == 1
        if highlighted {
            let pill = CGRect(x: panel.minX + inset, y: centerY - 58, width: panel.width - inset * 2, height: 116)
            fillVertical(
                context, continuousRect(pill, radius: 34), [srgb(0x4FA2FF), srgb(0x1F66EE)],
                from: pill.minY, to: pill.maxY)
        }
        let ink = highlighted ? srgb(0xFFFFFF) : srgb(0xBCCDE4)
        context.setFillColor(ink)
        if detailed {
            let glyph = CGRect(x: glyphX, y: centerY - 23, width: 46, height: 46)
            context.addPath(continuousRect(glyph, radius: 13))
            context.fillPath()
        }
        let barX = detailed ? glyphX + 72 : glyphX
        let length = highlighted ? 170 : barLengths[row] + (detailed ? 0 : 72)
        context.addPath(capsule(CGRect(x: barX, y: centerY - barHeight / 2, width: length, height: barHeight)))
        context.fillPath()
        if highlighted { drawArrow(context, tipX: panel.maxX - inset - 46, centerY: centerY, detailed: detailed) }
    }
}

func drawArrow(_ context: CGContext, tipX: CGFloat, centerY: CGFloat, detailed: Bool) {
    let head: CGFloat = 30
    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: tipX - 84, y: centerY))
    arrow.addLine(to: CGPoint(x: tipX, y: centerY))
    arrow.move(to: CGPoint(x: tipX - head, y: centerY - head))
    arrow.addLine(to: CGPoint(x: tipX, y: centerY))
    arrow.addLine(to: CGPoint(x: tipX - head, y: centerY + head))
    context.addPath(arrow)
    context.setStrokeColor(srgb(0xFFFFFF))
    context.setLineWidth(detailed ? 20 : 28)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()
}

func drawSparkles(_ context: CGContext, scale: CGFloat, detailed: Bool) {
    var stars = [(sparkleCenter, sparkleRadius)]
    if detailed { stars.append((CGPoint(x: 850, y: 408), 42)) }
    for (center, radius) in stars {
        let shape = sparkle(center: center, radius: radius)
        context.saveGState()
        setShadow(context, scale: scale, drop: 8, blur: 24, color: srgb(0x0A2A6E, 0.35))
        context.addPath(shape)
        context.setFillColor(srgb(0xFFFFFF))
        context.fillPath()
        context.restoreGState()
        fillVertical(
            context, shape, [srgb(0xFFFFFF), srgb(0xD8E8FF)], from: center.y - radius, to: center.y + radius)
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
    drawMenu(context, scale: scale, detailed: detailed)
    drawSparkles(context, scale: scale, detailed: detailed)
    guard let image = context.makeImage() else { fatalError("Image creation failed") }
    return image
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

try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)
var slots: [IconSlot] = []
for points in pointSizes {
    for factor in [1, 2] {
        let filename = "icon_\(points)x\(points)\(factor == 2 ? "@2x" : "").png"
        writePNG(renderIcon(pixels: points * factor), to: iconSet.appending(path: filename))
        slots.append(IconSlot(filename: filename, scale: "\(factor)x", size: "\(points)x\(points)"))
    }
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let newline = Data("\n".utf8)
try (encoder.encode(IconSetContents(images: slots)) + newline).write(to: iconSet.appending(path: "Contents.json"))
try (encoder.encode(CatalogContents()) + newline).write(to: catalog.appending(path: "Contents.json"))
print("Wrote \(slots.count) icons to \(iconSet.path)")
