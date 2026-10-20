import CoreGraphics
import Foundation

/// 8-bit RGBA with straight alpha, in `colorSpace`.
public struct PixelBuffer: Sendable {
    public let width: Int
    public let height: Int
    public var rgba: [UInt8]
    public let colorSpace: CGColorSpace

    public init(width: Int, height: Int, rgba: [UInt8], colorSpace: CGColorSpace = PixelBuffer.sRGB) {
        precondition(rgba.count == width * height * 4, "RGBA length must match the dimensions")
        self.width = width
        self.height = height
        self.rgba = rgba
        self.colorSpace = colorSpace
    }

    // The named sRGB space always exists.
    public static let sRGB: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    public var pixelCount: Int { width * height }

    public var isOpaque: Bool {
        stride(from: 3, to: rgba.count, by: 4).allSatisfy { rgba[$0] == 255 }
    }

    /// Reads 8-bit images byte-exactly; draws anything else.
    public init(cgImage image: CGImage) throws {
        if let exact = PixelBuffer(exactly: image) {
            self = exact
        } else {
            try self.init(drawing: image, colorSpace: Self.workingSpace(of: image))
        }
    }

    /// `nil` unless readable losslessly.
    public init?(exactly image: CGImage) {
        guard let exact = Self.exactPixels(of: image) else { return nil }
        self.init(width: image.width, height: image.height, rgba: exact, colorSpace: Self.workingSpace(of: image))
    }

    private static func workingSpace(of image: CGImage) -> CGColorSpace {
        image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? sRGB
    }

    private init(drawing image: CGImage, colorSpace: CGColorSpace) throws {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw FormatError.corrupt("cannot draw image") }
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[index + 3])
            guard alpha > 0, alpha < 255 else { continue }
            for channel in 0..<3 {
                pixels[index + channel] = UInt8(min(255, (Int(pixels[index + channel]) * 255 + alpha / 2) / alpha))
            }
        }
        self.init(width: width, height: height, rgba: pixels, colorSpace: colorSpace)
    }

    private static func exactPixels(of image: CGImage) -> [UInt8]? {
        guard image.bitsPerComponent == 8, let data = image.dataProvider?.data,
            let bytes = CFDataGetBytePtr(data)
        else { return nil }
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        guard order == [] || order == .byteOrder32Big || order == .byteOrderDefault else { return nil }
        let alpha = image.alphaInfo
        let model = image.colorSpace?.model
        let components = image.bitsPerPixel / 8
        let stride = image.bytesPerRow
        var pixels = [UInt8](repeating: 255, count: image.width * image.height * 4)
        let layout: (r: Int, g: Int, b: Int, a: Int?)
        switch (model, components, alpha) {
        case (.rgb, 4, .last), (.rgb, 4, .noneSkipLast): layout = (0, 1, 2, alpha == .last ? 3 : nil)
        case (.rgb, 4, .first), (.rgb, 4, .noneSkipFirst): layout = (1, 2, 3, alpha == .first ? 0 : nil)
        case (.rgb, 3, .none): layout = (0, 1, 2, nil)
        case (.monochrome, 1, .none): layout = (0, 0, 0, nil)
        case (.monochrome, 2, .last): layout = (0, 0, 0, 1)
        default: return nil
        }
        for y in 0..<image.height {
            let row = bytes + y * stride
            for x in 0..<image.width {
                let source = row + x * components
                let target = (y * image.width + x) * 4
                pixels[target] = source[layout.r]
                pixels[target + 1] = source[layout.g]
                pixels[target + 2] = source[layout.b]
                if let alphaOffset = layout.a { pixels[target + 3] = source[alphaOffset] }
            }
        }
        return pixels
    }

    public func makeCGImage() throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
            )
        else { throw FormatError.encoderFailure("cannot create image") }
        return image
    }
}
