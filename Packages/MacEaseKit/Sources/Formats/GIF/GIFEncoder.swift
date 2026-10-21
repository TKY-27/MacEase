import Foundation

public struct GIFFrame: Sendable {
    public var pixels: PixelBuffer
    public var duration: Double

    public init(pixels: PixelBuffer, duration: Double) {
        self.pixels = pixels
        self.duration = duration
    }
}

public struct GIFOptions: Sendable {
    public enum PaletteScope: String, Codable, Sendable {
        case global
        case perFrame
    }

    public var colors: Int
    public var dithering: Dithering
    public var loopCount: UInt16?
    public var loops: Bool {
        get { loopCount != nil }
        set { loopCount = newValue ? 0 : nil }
    }
    public var paletteScope: PaletteScope

    public init(
        colors: Int = 256, dithering: Dithering = .ordered, loops: Bool = true, paletteScope: PaletteScope = .global
    ) {
        self.colors = colors
        self.dithering = dithering
        self.loopCount = loops ? 0 : nil
        self.paletteScope = paletteScope
    }

    public init(
        colors: Int = 256, dithering: Dithering = .ordered, loopCount: UInt16?, paletteScope: PaletteScope = .global
    ) {
        self.colors = colors
        self.dithering = dithering
        self.loopCount = loopCount
        self.paletteScope = paletteScope
    }
}

public enum GIFEncoder {
    /// GIF89a block introducers and flags.
    private enum Marker {
        static let extensionIntroducer: UInt8 = 0x21
        static let applicationLabel: UInt8 = 0xFF
        static let graphicControlLabel: UInt8 = 0xF9
        static let imageSeparator: UInt8 = 0x2C
        static let trailer: UInt8 = 0x3B
        static let colorTableFlag: UInt8 = 0x80
        /// Eight bits of color resolution.
        static let colorResolution: UInt8 = 0x70
    }

    /// Per-channel slack for reusing previous pixels.
    private static let stillTolerance = 4
    private static let paletteSampleFrames = 24
    private static let maximumFrameDuration = Double(UInt16.max) / 100

    public static func encode(_ frames: [GIFFrame], options: GIFOptions) throws -> Data {
        guard let first = frames.first else { throw FormatError.encoderFailure("no frames") }
        let width = first.pixels.width
        let height = first.pixels.height
        guard width > 0, height > 0, width <= 65_535, height <= 65_535,
            frames.allSatisfy({ $0.pixels.width == width && $0.pixels.height == height })
        else { throw FormatError.encoderFailure("frames must share one size") }
        guard frames.allSatisfy({ validDuration($0.duration) }) else {
            throw FormatError.corrupt(
                String(localized: "GIF frame duration out of range", comment: "Invalid animation timing"))
        }

        let animated = frames.count > 1
        let hasRealTransparency = frames.contains { !$0.pixels.isOpaque }
        // Real transparency needs disposal, not differencing.
        let differencing = animated && !hasRealTransparency
        let reservesTransparent = animated || hasRealTransparency
        let colorCount = min(max(options.colors, 2), 256)
        let paletteSize = reservesTransparent ? colorCount - 1 : colorCount
        let globalPalette =
            options.paletteScope == .global
            ? palette(for: sampled(frames).map(\.pixels), count: paletteSize) : nil

        var output = header(
            width: width, height: height, globalPalette: globalPalette,
            reservesTransparent: reservesTransparent, loopCount: animated ? options.loopCount : nil
        )
        var encoding = FrameEncoding(
            width: width, height: height, options: options, globalPalette: globalPalette,
            reservesTransparent: reservesTransparent, differencing: differencing,
            disposal: hasRealTransparency ? 2 : 1, animated: animated, transparentFirst: false
        )
        for frame in frames {
            output.append(encoding.encode(frame))
        }
        output.append(Marker.trailer)
        return output
    }

    public final class Stream {
        private let width: Int
        private let height: Int
        private let output: PatchableFile
        private var encoding: FrameEncoding
        private var pendingFrame: GIFFrame?
        private var firstIsTransparent = false
        private var finished = false

        public init(width: Int, height: Int, options: GIFOptions, to url: URL) throws {
            guard options.paletteScope == .perFrame else {
                throw FormatError.encoderFailure("GIF streaming requires per-frame palettes")
            }
            guard width > 0, height > 0, width <= 65_535, height <= 65_535 else {
                throw FormatError.encoderFailure("invalid GIF dimensions")
            }
            self.width = width
            self.height = height
            encoding = FrameEncoding(
                width: width, height: height, options: options, globalPalette: nil,
                reservesTransparent: true, differencing: false, disposal: 2,
                animated: true, transparentFirst: true
            )
            output = try PatchableFile(url: url)
            // Aligns disposal background with transparent index.
            try output.append(
                GIFEncoder.header(
                    width: width, height: height,
                    globalPalette: [PaletteColor(red: 0, green: 0, blue: 0, alpha: 0)],
                    reservesTransparent: false, loopCount: options.loopCount
                ))
        }

        public func add(_ frame: GIFFrame) throws {
            guard !finished else { throw FormatError.encoderFailure("GIF stream is finished") }
            guard frame.pixels.width == width, frame.pixels.height == height else {
                throw FormatError.encoderFailure("frames must share one size")
            }
            guard GIFEncoder.validDuration(frame.duration) else {
                throw FormatError.encoderFailure("invalid GIF frame duration")
            }
            let isTransparent = !frame.pixels.isOpaque
            if let pendingFrame {
                do {
                    try append(pendingFrame, clearAfter: isTransparent)
                } catch {
                    finished = true
                    throw error
                }
            } else {
                firstIsTransparent = isTransparent
            }
            pendingFrame = frame
        }

        public func finish() throws {
            guard !finished else { throw FormatError.encoderFailure("GIF stream is finished") }
            guard let pendingFrame else { throw FormatError.encoderFailure("no frames") }
            finished = true
            try append(pendingFrame, clearAfter: encoding.options.loops && firstIsTransparent)
            self.pendingFrame = nil
            encoding.drawnSource = nil
            try output.append(Data([Marker.trailer]))
            try output.close()
        }

        private func append(_ frame: GIFFrame, clearAfter: Bool) throws {
            encoding.differencing = frame.pixels.isOpaque && !clearAfter
            encoding.disposal = encoding.differencing ? 1 : 2
            if !encoding.differencing { encoding.drawnSource = nil }
            try output.append(encoding.encode(frame))
        }
    }

    private static func validDuration(_ duration: Double) -> Bool {
        duration.isFinite && duration >= 0 && duration <= maximumFrameDuration
    }

    private static func header(
        width: Int, height: Int, globalPalette: [PaletteColor]?, reservesTransparent: Bool, loopCount: UInt16?
    ) -> Data {
        var output = Data("GIF89a".utf8)
        output.appendLittleEndian(UInt16(width))
        output.appendLittleEndian(UInt16(height))
        if let globalPalette {
            let table = colorTable(globalPalette, reservesTransparent: reservesTransparent)
            output.append(Marker.colorTableFlag | Marker.colorResolution | table.sizeField)
            // Disposal restores to the transparent entry.
            output.append(contentsOf: [UInt8(reservesTransparent ? globalPalette.count : 0), 0])
            output.append(table.bytes)
        } else {
            output.append(contentsOf: [Marker.colorResolution, 0, 0])
        }
        if let loopCount {
            output.append(contentsOf: [Marker.extensionIntroducer, Marker.applicationLabel, 0x0B])
            output.append(Data("NETSCAPE2.0".utf8))
            output.append(contentsOf: [0x03, 0x01])
            output.appendLittleEndian(loopCount)
            output.append(0)
        }

        return output
    }

    private struct FrameEncoding {
        let width: Int
        let height: Int
        let options: GIFOptions
        let globalPalette: [PaletteColor]?
        let reservesTransparent: Bool
        var differencing: Bool
        var disposal: UInt8
        let animated: Bool
        let transparentFirst: Bool
        var drawnSource: [UInt8]?
        var timing = DelayRounding()

        mutating func encode(_ frame: GIFFrame) -> Data {
            let colorCount = min(max(options.colors, 2), 256)
            let colors =
                globalPalette
                ?? GIFEncoder.palette(
                    for: [frame.pixels], count: reservesTransparent ? colorCount - 1 : colorCount)
            let transparent = PaletteColor(red: 0, green: 0, blue: 0, alpha: 0)
            let transparentIndex = reservesTransparent ? (transparentFirst ? 0 : colors.count) : nil
            let fullPalette =
                reservesTransparent ? (transparentFirst ? [transparent] + colors : colors + [transparent]) : colors
            var skipped = stride(from: 3, to: frame.pixels.rgba.count, by: 4).map {
                frame.pixels.rgba[$0] < PaletteColor.opacityCutoff
            }
            if differencing, let drawnSource {
                for (pixel, still) in GIFEncoder.stillMask(frame.pixels.rgba, previous: drawnSource).enumerated()
                where still {
                    skipped[pixel] = true
                }
            }
            let bounds =
                differencing && drawnSource != nil
                ? GIFEncoder.changedBounds(skipped, width: width, height: height) : (0, 0, width, height)
            if differencing {
                // Last drawn source values prevent slow drift.
                var updated = drawnSource ?? frame.pixels.rgba
                for pixel in skipped.indices where !skipped[pixel] {
                    updated.replaceSubrange(
                        (pixel * 4)..<(pixel * 4 + 4), with: frame.pixels.rgba[(pixel * 4)..<(pixel * 4 + 4)])
                }
                drawnSource = updated
            }
            var coder = FrameCoder(
                palette: fullPalette, transparentIndex: transparentIndex, dithering: options.dithering,
                codeSize: max(2, GIFEncoder.bitsNeeded(fullPalette.count))
            )
            let compressed = coder.encode(frame.pixels, skipped: skipped, bounds: bounds)
            var control: FrameControl?
            if reservesTransparent {
                let delay: UInt16 = animated ? timing.next(frame.duration) : 0
                control = FrameControl(disposal: disposal, transparentIndex: transparentIndex, delay: delay)
            }
            var output = Data()
            GIFEncoder.appendFrame(
                compressed, bounds: bounds, codeSize: coder.codeSize,
                localPalette: globalPalette == nil ? (transparentFirst ? fullPalette : colors) : nil,
                reservesTransparent: reservesTransparent && !transparentFirst,
                control: control, into: &output
            )
            return output
        }
    }

    private static func sampled(_ frames: [GIFFrame]) -> [GIFFrame] {
        guard frames.count > paletteSampleFrames else { return frames }
        let step = Double(frames.count) / Double(paletteSampleFrames)
        return (0..<paletteSampleFrames).map { frames[Int(Double($0) * step)] }
    }

    private static func palette(for buffers: [PixelBuffer], count: Int) -> [PaletteColor] {
        let quantizer = ColorQuantizer(includesAlpha: false)
        let pixels = buffers.flatMap(\.rgba)
        let transparent = { (pixel: Int) in pixels[pixel * 4 + 3] < PaletteColor.opacityCutoff }
        if let exact = ColorQuantizer.exactPalette(of: pixels, limit: count, includesAlpha: false, skip: transparent) {
            return exact.isEmpty ? [PaletteColor(red: 0, green: 0, blue: 0, alpha: 255)] : exact
        }
        let samples = ColorQuantizer.samples(of: pixels, includesAlpha: false, skip: transparent)
        let colors = quantizer.palette(from: samples, count: count)
        return colors.isEmpty ? [PaletteColor(red: 0, green: 0, blue: 0, alpha: 255)] : colors
    }

    private static func stillMask(_ current: [UInt8], previous: [UInt8]) -> [Bool] {
        stride(from: 0, to: current.count, by: 4).map { base -> Bool in
            guard current[base + 3] >= PaletteColor.opacityCutoff, previous[base + 3] == 255 else { return false }
            for channel in 0..<3 {
                let difference = abs(Int(current[base + channel]) - Int(previous[base + channel]))
                if difference > stillTolerance { return false }
            }
            return true
        }
    }

    private static func changedBounds(_ skipped: [Bool], width: Int, height: Int) -> (Int, Int, Int, Int) {
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width where !skipped[y * width + x] {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return (0, 0, 1, 1) }
        return (minX, minY, maxX - minX + 1, maxY - minY + 1)
    }

    private static func bitsNeeded(_ count: Int) -> Int {
        var bits = 1
        while 1 << bits < count { bits += 1 }
        return bits
    }

    private static func colorTable(_ colors: [PaletteColor], reservesTransparent: Bool) -> (
        bytes: Data, sizeField: UInt8
    ) {
        let bits = bitsNeeded(colors.count + (reservesTransparent ? 1 : 0))
        var bytes = Data(capacity: 3 << bits)
        for index in 0..<(1 << bits) {
            let color = index < colors.count ? colors[index] : PaletteColor(red: 0, green: 0, blue: 0, alpha: 0)
            bytes.append(contentsOf: [color.red, color.green, color.blue])
        }
        return (bytes, UInt8(bits - 1))
    }

    private struct FrameControl {
        let disposal: UInt8
        let transparentIndex: Int?
        let delay: UInt16
    }

    private static func appendFrame(
        _ compressed: [UInt8],
        bounds: (x: Int, y: Int, width: Int, height: Int),
        codeSize: Int,
        localPalette: [PaletteColor]?,
        reservesTransparent: Bool,
        control: FrameControl?,
        into output: inout Data
    ) {
        if let control {
            output.append(contentsOf: [
                Marker.extensionIntroducer, Marker.graphicControlLabel, 0x04,
                control.disposal << 2 | (control.transparentIndex == nil ? 0 : 1),
            ])
            output.appendLittleEndian(control.delay)
            output.append(contentsOf: [UInt8(control.transparentIndex ?? 0), 0])
        }
        output.append(Marker.imageSeparator)
        output.appendLittleEndian(UInt16(bounds.x))
        output.appendLittleEndian(UInt16(bounds.y))
        output.appendLittleEndian(UInt16(bounds.width))
        output.appendLittleEndian(UInt16(bounds.height))
        if let localPalette {
            let table = colorTable(localPalette, reservesTransparent: reservesTransparent)
            output.append(Marker.colorTableFlag | table.sizeField)
            output.append(table.bytes)
        } else {
            output.append(0)
        }
        output.append(UInt8(codeSize))
        var offset = 0
        while offset < compressed.count {
            let length = min(255, compressed.count - offset)
            output.append(UInt8(length))
            output.append(contentsOf: compressed[offset..<(offset + length)])
            offset += length
        }
        output.append(0)
    }
}

/// Dithers and compresses together, preferring dictionary matches.
private struct FrameCoder {
    /// RGB distance a dictionary match may add.
    private static func matchTolerance(for dithering: Dithering) -> Float {
        dithering == .ordered ? 7 : 4
    }

    let codeSize: Int
    private let palette: [PaletteColor]
    private let colors: [SIMD3<Float>]
    private let transparentIndex: Int?
    private let dithering: Dithering
    private var mapper: PaletteMapper

    init(palette: [PaletteColor], transparentIndex: Int?, dithering: Dithering, codeSize: Int) {
        self.palette = palette
        self.colors = palette.map { SIMD3(Float($0.red), Float($0.green), Float($0.blue)) }
        self.transparentIndex = transparentIndex
        self.dithering = dithering
        self.codeSize = codeSize
        mapper = PaletteMapper(
            palette: palette, includesAlpha: false, dithering: dithering, transparentIndex: transparentIndex
        )
    }

    mutating func encode(_ pixels: PixelBuffer, skipped: [Bool], bounds: (x: Int, y: Int, width: Int, height: Int))
        -> [UInt8]
    {
        var lzw = LZWEncoder(minimumCodeSize: codeSize)
        var current = [SIMD3<Float>](repeating: .zero, count: bounds.width + 2)
        var next = current
        for y in bounds.y..<(bounds.y + bounds.height) {
            for column in 0..<bounds.width {
                let x = bounds.x + column
                let pixel = y * pixels.width + x
                if skipped[pixel], let transparentIndex {
                    lzw.append(UInt8(transparentIndex))
                    continue
                }
                let base = pixel * 4
                var wanted = SIMD3<Float>(
                    Float(pixels.rgba[base]), Float(pixels.rgba[base + 1]), Float(pixels.rgba[base + 2]))
                switch dithering {
                case .floydSteinberg: wanted += current[column + 1]
                case .ordered:
                    wanted += SIMD3(
                        repeating: PaletteMapper.bayer[(y % 8) * 8 + x % 8] * PaletteMapper.orderedAmplitude)
                case .none: break
                }
                wanted = wanted.clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 255))
                let nearest = mapper.index(
                    red: UInt8(wanted.x.rounded()), green: UInt8(wanted.y.rounded()), blue: UInt8(wanted.z.rounded()),
                    alpha: 255
                )
                let chosen = dithering == .none ? nearest : preferredMatch(for: wanted, nearest: nearest, in: lzw)
                lzw.append(UInt8(chosen))
                guard dithering == .floydSteinberg else { continue }
                let error = (wanted - colors[chosen]) * PaletteMapper.diffusion
                current[column + 2] += error * (7 / 16)
                next[column] += error * (3 / 16)
                next[column + 1] += error * (5 / 16)
                next[column + 2] += error * (1 / 16)
            }
            swap(&current, &next)
            next = [SIMD3<Float>](repeating: .zero, count: bounds.width + 2)
        }
        return lzw.finish()
    }

    private func preferredMatch(for wanted: SIMD3<Float>, nearest: Int, in lzw: LZWEncoder) -> Int {
        let nearestDistance = distance(colors[nearest], wanted)
        var best = nearest
        var bestDistance = nearestDistance + Self.matchTolerance(for: dithering)
        lzw.forEachExtension { symbol in
            let candidate = Int(symbol)
            guard candidate != transparentIndex else { return }
            let candidateDistance = distance(colors[candidate], wanted)
            if candidateDistance <= bestDistance {
                best = candidate
                bestDistance = candidateDistance
            }
        }
        return best
    }

    private func distance(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> Float {
        let difference = lhs - rhs
        return (difference * difference).sum().squareRoot()
    }
}

/// Keeps centisecond delays from drifting over time.
private struct DelayRounding {
    private var elapsed = 0.0
    private var emitted = 0

    mutating func next(_ duration: Double) -> UInt16 {
        elapsed += duration * 100
        let target = Int(elapsed.rounded())
        let delay = max(target - emitted, 2)
        emitted += delay
        return UInt16(min(delay, Int(UInt16.max)))
    }
}
