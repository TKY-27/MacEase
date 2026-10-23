import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Formats

extension Fixtures {
    /// Static gradient, drifting hue band, moving ball.
    static func gradientFrames(count: Int = 30, width: Int = 320, height: Int = 180) -> [PixelBuffer] {
        (0..<count).map { frame in
            let phase = Double(frame) / Double(count)
            var rgba = [UInt8](repeating: 255, count: width * height * 4)
            let ballX = Double(width) * (0.2 + 0.6 * phase)
            let ballY = Double(height) * 0.5
            for y in 0..<height {
                for x in 0..<width {
                    let u = Double(x) / Double(width)
                    let v = Double(y) / Double(height)
                    var red = 40 + 180 * u
                    var green = 60 + 150 * v
                    var blue = 200 - 120 * u * v
                    if v > 0.7 {
                        let hue = (u + phase) * 2 * Double.pi
                        red = 128 + 100 * sin(hue)
                        green = 128 + 100 * sin(hue + 2.1)
                        blue = 128 + 100 * sin(hue + 4.2)
                    }
                    let distance = hypot(Double(x) - ballX, Double(y) - ballY) / 30
                    if distance < 1 {
                        let weight = 1 - distance * distance
                        red = red * (1 - weight) + 250 * weight
                        green = green * (1 - weight) + 210 * weight
                        blue = blue * (1 - weight) + 40 * weight
                    }
                    let base = (y * width + x) * 4
                    rgba[base] = UInt8(red.rounded())
                    rgba[base + 1] = UInt8(green.rounded())
                    rgba[base + 2] = UInt8(blue.rounded())
                }
            }
            return PixelBuffer(width: width, height: height, rgba: rgba)
        }
    }
}

@Suite struct GIFEncoderTests {
    @Test func streamedGradientMeetsQualityAndBeatsImageIO() async throws {
        let video = FileManager.default.temporaryDirectory.appending(path: "gradient-\(UUID().uuidString).mp4")
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: video) } }
        try await VideoFixture.write(Fixtures.gradientFrames(), fps: 15, to: video)
        let frames = try await VideoFixture.frames(of: video, count: 30, fps: 15)
        let output = FileManager.default.temporaryDirectory.appending(path: "gradient-\(UUID().uuidString).gif")
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: output) } }
        let encoder = try GIFEncoder.Stream(
            width: 320, height: 180, options: GIFOptions(paletteScope: .perFrame), to: output)
        for frame in frames { try encoder.add(GIFFrame(pixels: frame, duration: 1.0 / 15)) }
        try encoder.finish()
        let bitstream = try Data(contentsOf: output)
        let decoded = try decodedFrames(bitstream)
        #expect(decoded.count == frames.count)
        let ssim = zip(frames, decoded).map { SSIM.compare($0, $1) }.reduce(0, +) / Double(frames.count)
        #expect(ssim >= 0.93, "SSIM \(ssim)")
        let reference = try imageIOGIF(frames, delay: 1.0 / 15)
        #expect(bitstream.count < reference.count, "\(bitstream.count) vs ImageIO \(reference.count)")
    }

    private func decodedFrames(_ data: Data) throws -> [PixelBuffer] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try (0..<CGImageSourceGetCount(source)).map { index in
            try PixelBuffer(cgImage: try #require(CGImageSourceCreateImageAtIndex(source, index, nil)))
        }
    }

    private func imageIOGIF(_ frames: [PixelBuffer], delay: Double) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames.count, nil)
        )
        let loop = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        CGImageDestinationSetProperties(destination, loop)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
        for frame in frames { CGImageDestinationAddImage(destination, try frame.makeCGImage(), frameProperties) }
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func animatedGradientMeetsQualityAndBeatsImageIO() async throws {
        let video = FileManager.default.temporaryDirectory.appending(path: "gradient-\(UUID().uuidString).mp4")
        TestTemporaryFolders.register(video)
        try await VideoFixture.write(Fixtures.gradientFrames(), fps: 15, to: video)
        let frames = try await VideoFixture.frames(of: video, count: 30, fps: 15)
        let gif = try GIFEncoder.encode(
            frames.map { GIFFrame(pixels: $0, duration: 1.0 / 15) },
            options: GIFOptions(colors: 256, dithering: .ordered)
        )
        let decoded = try decodedFrames(gif)
        #expect(decoded.count == frames.count)
        let ssim = zip(frames, decoded).map { SSIM.compare($0, $1) }.reduce(0, +) / Double(frames.count)
        let reference = try imageIOGIF(frames, delay: 1.0 / 15)
        #expect(ssim >= 0.93, "SSIM \(ssim)")
        #expect(gif.count < reference.count, "\(gif.count) vs ImageIO \(reference.count)")
    }

    @Test func floydSteinbergStaysAboveTheQualityBar() throws {
        let frames = Fixtures.gradientFrames(count: 10)
        let gif = try GIFEncoder.encode(
            frames.map { GIFFrame(pixels: $0, duration: 0.1) }, options: GIFOptions(dithering: .floydSteinberg)
        )
        let ssim = zip(frames, try decodedFrames(gif)).map { SSIM.compare($0, $1) }.reduce(0, +) / 10
        #expect(ssim >= 0.93, "SSIM \(ssim)")
    }

    @Test func keepsTimingAndLoopCount() throws {
        let frames = Fixtures.gradientFrames(count: 6, width: 40, height: 30)
        let gif = try GIFEncoder.encode(
            frames.map { GIFFrame(pixels: $0, duration: 1.0 / 15) },
            options: GIFOptions(colors: 64, dithering: .ordered, loops: true)
        )
        let source = try #require(CGImageSourceCreateWithData(gif as CFData, nil))
        let fileProperties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let gifProperties = fileProperties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        #expect(gifProperties?[kCGImagePropertyGIFLoopCount] as? Int == 0)
        let delays = (0..<6).compactMap { index -> Double? in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let frame = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            return frame?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        }
        #expect(CGImageSourceGetCount(source) == frames.count)
        #expect(delays.count == frames.count)
        for delay in delays { #expect(abs(delay - 1.0 / 15) < 0.011) }
        #expect(abs(delays.reduce(0, +) - 0.4) < 0.011)
    }

    @Test func singleFrameKeepsTransparencyWithLocalPalette() throws {
        var pixels = Fixtures.photo(width: 48, height: 32)
        for index in stride(from: 3, to: pixels.rgba.count, by: 4) where index / 4 % 48 < 10 { pixels.rgba[index] = 0 }
        let gif = try GIFEncoder.encode(
            [GIFFrame(pixels: pixels, duration: 0)],
            options: GIFOptions(colors: 32, dithering: .none, loops: false, paletteScope: .perFrame)
        )
        let decoded = try #require(try decodedFrames(gif).first)
        #expect(decoded.rgba[3] == 0)
        #expect(decoded.rgba[20 * 4 + 3] == 255)
    }

    @Test func lzwRoundTripsThroughImageIOAcrossTableResets() throws {
        var random = FixtureRandom(seed: 3)
        let noisy = PixelBuffer(
            width: 256, height: 256,
            rgba: (0..<(256 * 256)).flatMap { _ -> [UInt8] in
                let value = UInt8(random.next() % 4 * 85)
                return [value, value, value, 255]
            }
        )
        let gif = try GIFEncoder.encode(
            [GIFFrame(pixels: noisy, duration: 0)], options: GIFOptions(colors: 4, dithering: .none))
        #expect(try decodedFrames(gif).first?.rgba == noisy.rgba)
    }
}
