import CoreGraphics
import Foundation
import Testing

@testable import Formats

extension Fixtures {
    /// Flat shapes, a ring and a bar.
    static func logo(size: Int = 256) -> PixelBuffer {
        let space = PixelBuffer.sRGB
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        rgba.withUnsafeMutableBytes { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return }
            context.setShouldAntialias(false)
            let scale = CGFloat(size) / 256
            context.scaleBy(x: scale, y: scale)
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            context.setFillColor(CGColor(red: 0.85, green: 0.1, blue: 0.15, alpha: 1))
            context.fillEllipse(in: CGRect(x: 24, y: 120, width: 110, height: 110))
            context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1))
            context.addPath(
                CGPath(
                    roundedRect: CGRect(x: 120, y: 30, width: 110, height: 80), cornerWidth: 18, cornerHeight: 18,
                    transform: nil))
            context.fillPath()
            context.setFillColor(CGColor(red: 0.1, green: 0.65, blue: 0.3, alpha: 1))
            context.move(to: CGPoint(x: 30, y: 30))
            context.addLine(to: CGPoint(x: 110, y: 30))
            context.addLine(to: CGPoint(x: 70, y: 105))
            context.fillPath()
            context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
            context.addEllipse(in: CGRect(x: 150, y: 130, width: 90, height: 90))
            context.addEllipse(in: CGRect(x: 175, y: 155, width: 40, height: 40))
            context.fillPath(using: .evenOdd)
            context.fill(CGRect(x: 20, y: 236, width: 216, height: 8))
        }
        return PixelBuffer(width: size, height: size, rgba: rgba)
    }
}

@Suite struct SVGTracerTests {
    /// Parses the tracer's M, C and Z.
    private func path(from data: String) throws -> CGPath {
        let path = CGMutablePath()
        let scanner = Scanner(string: data)
        scanner.charactersToBeSkipped = CharacterSet(charactersIn: " ")
        func number() throws -> CGFloat {
            CGFloat(try #require(scanner.scanDouble()))
        }
        while !scanner.isAtEnd {
            let command = try #require(scanner.scanCharacter())
            switch command {
            case "M": path.move(to: CGPoint(x: try number(), y: try number()))
            case "C":
                let c1 = CGPoint(x: try number(), y: try number())
                let c2 = CGPoint(x: try number(), y: try number())
                path.addCurve(to: CGPoint(x: try number(), y: try number()), control1: c1, control2: c2)
            case "Z": path.closeSubpath()
            default: Issue.record("unexpected command \(command)")
            }
        }
        return path
    }

    private func rasterize(_ path: CGPath, size: Int) -> [Bool] {
        var gray = [UInt8](repeating: 0, count: size * size)
        gray.withUnsafeMutableBytes { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
                )
            else { return }
            context.setShouldAntialias(false)
            context.translateBy(x: 0, y: CGFloat(size))
            context.scaleBy(x: 1, y: -1)
            context.setFillColor(gray: 1, alpha: 1)
            context.addPath(path)
            context.fillPath(using: .evenOdd)
        }
        return gray.map { $0 > 127 }
    }

    @Test func eachColorLayerReachesTheIoUTarget() throws {
        let size = 256
        let logo = Fixtures.logo(size: size)
        let layers = SVGTracer.trace(logo, colors: 5)
        let document = SVGTracer.svg(layers, width: size, height: size)
        #expect(XMLParser(data: Data(document.utf8)).parse())
        let pathData = document.split(separator: "\n").compactMap { line -> String? in
            guard let range = line.range(of: #" d=""#) else { return nil }
            return String(line[range.upperBound...].dropLast(3))
        }
        #expect(pathData.count == 5)
        let drawn = try pathData.map { rasterize(try path(from: $0), size: size) }
        for (index, layer) in layers.enumerated() {
            let original = stride(from: 0, to: logo.rgba.count, by: 4).map { base in
                logo.rgba[base] == layer.color.red && logo.rgba[base + 1] == layer.color.green
                    && logo.rgba[base + 2] == layer.color.blue
            }
            let visible = (0..<(size * size)).map { pixel in
                drawn[index][pixel] && !drawn[(index + 1)...].contains { $0[pixel] }
            }
            let intersection = zip(original, visible).filter { $0 && $1 }.count
            let union = zip(original, visible).filter { $0 || $1 }.count
            let iou = Double(intersection) / Double(union)
            #expect(iou >= 0.95, "layer \(index) IoU \(iou)")
        }
    }

    @Test func monochromeTracesOnlyTheDarkShapes() throws {
        let layers = SVGTracer.trace(Fixtures.logo(size: 128), colors: 1)
        #expect(layers.count == 1)
        #expect(layers[0].color == PaletteColor(red: 0, green: 0, blue: 0, alpha: 255))
        #expect(!layers[0].contours.isEmpty)
    }
}
