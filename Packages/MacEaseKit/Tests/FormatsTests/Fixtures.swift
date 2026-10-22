import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Formats

/// Deterministic SplitMix64, so fixtures never change.
struct FixtureRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}

enum Fixtures {
    /// BGRA, as the video encoders take it.
    static func pixelBuffer(_ pixels: PixelBuffer) throws -> CVPixelBuffer {
        let image = try VideoDecoders.makeImage(width: pixels.width, height: pixels.height)
        CVPixelBufferLockBaseAddress(image, [])
        defer { CVPixelBufferUnlockBaseAddress(image, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(image)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(image)
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let source = (y * pixels.width + x) * 4
                let target = y * rowBytes + x * 4
                base[target] = pixels.rgba[source + 2]
                base[target + 1] = pixels.rgba[source + 1]
                base[target + 2] = pixels.rgba[source]
                base[target + 3] = pixels.rgba[source + 3]
            }
        }
        return image
    }

    /// Gradient, soft blobs, texture and noise.
    static func photo(width: Int = 480, height: Int = 360, seed: UInt64 = 7, noise: Double = 6) -> PixelBuffer {
        var random = FixtureRandom(seed: seed)
        var pixels = [Double](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            let t = Double(y) / Double(height)
            for x in 0..<width {
                let base = (y * width + x) * 3
                pixels[base] = 70 + 150 * t
                pixels[base + 1] = 120 + 60 * t
                pixels[base + 2] = 220 - 120 * t
            }
        }
        for _ in 0..<40 {
            let cx = random.unit() * Double(width)
            let cy = random.unit() * Double(height)
            let radius = 15 + random.unit() * 90
            let color = [random.unit() * 255, random.unit() * 255, random.unit() * 255]
            let strength = 0.4 + random.unit() * 0.5
            for y in max(0, Int(cy - radius))..<min(height, Int(cy + radius)) {
                for x in max(0, Int(cx - radius))..<min(width, Int(cx + radius)) {
                    let distance = hypot(Double(x) - cx, Double(y) - cy) / radius
                    guard distance < 1 else { continue }
                    let weight = strength * (1 - distance * distance)
                    for channel in 0..<3 {
                        let index = (y * width + x) * 3 + channel
                        pixels[index] = pixels[index] * (1 - weight) + color[channel] * weight
                    }
                }
            }
        }
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let texture = 12 * sin(Double(x) * 0.09) * sin(Double(y) * 0.13)
                let lumaGrain = (random.unit() - 0.5) * noise
                for channel in 0..<3 {
                    let grain = lumaGrain + (random.unit() - 0.5) * noise / 4
                    let value = pixels[(y * width + x) * 3 + channel] + texture + grain
                    rgba[(y * width + x) * 4 + channel] = UInt8(min(max(value.rounded(), 0), 255))
                }
            }
        }
        return PixelBuffer(width: width, height: height, rgba: rgba)
    }

    static func encode(_ buffer: PixelBuffer, as type: UTType) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw FormatError.encoderFailure("destination")
        }
        CGImageDestinationAddImage(destination, try buffer.makeCGImage(), nil)
        guard CGImageDestinationFinalize(destination) else { throw FormatError.encoderFailure("finalize") }
        return data as Data
    }

    static func decode(_ data: Data) throws -> PixelBuffer {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw FormatError.corrupt("undecodable") }
        return try PixelBuffer(cgImage: image)
    }
}
