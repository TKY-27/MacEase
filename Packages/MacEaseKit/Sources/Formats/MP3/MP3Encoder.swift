import Foundation

public struct MP3EncoderOptions: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case constant(kilobits: Int)
        /// 0 is best, 9 smallest.
        case variable(quality: Int)
    }

    public static let constantBitrates = [128, 192, 256, 320]

    public var sampleRate: Int
    public var channels: Int
    public var mode: Mode

    public init(sampleRate: Int, channels: Int, mode: Mode) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.mode = mode
    }
}

/// MPEG-1 Layer III, from ISO/IEC 11172-3.
public final class MP3Encoder {
    private static let maximumReservoirBytes = 511
    private static let maximumPart23 = 4095
    /// Quality 0 tightens; each step loosens.
    private static let bestQualityDecibels = 22.0
    private static let qualityStepDecibels = 2.6
    private static let midSideRatio = 0.35
    /// Perceptual entropy overstates the bits needed.
    private static let entropyToBits = 0.5
    /// Easy granules still get this share.
    private static let lowDemandShare = 0.6
    /// Keeps alignment from overflowing the slot.
    private static let alignmentSlack = 16
    /// Matches subband timing to the input.
    private static let detectorDelay = 256
    /// 3 granules flush lookahead and filterbank delay.
    private static let flushGranules = 3
    private static let xingBitrateIndex = 9
    private static let compactionThreshold = 1 << 16

    private let options: MP3EncoderOptions
    private let tables: MP3Constants.RateTables
    private let cutoffLine: Int
    private let shortCutoffLine: Int
    private var channels: [ChannelState]
    private var queued: [[Float]]
    private var queueStart = 0
    private var pendingGranules: [[GranuleSpectrum]] = []
    private var assembler = FrameAssembler()
    private var paddingRemainder = 0
    private var frameStarts: [Int] = []
    private var streamBytes = 0
    private var previousMidSide = false
    private var finished = false

    private struct ChannelState {
        var analysis = PolyphaseAnalysis()
        var detector = TransientDetector()
        var detectorBacklog = [Float](repeating: 0, count: MP3Encoder.detectorDelay)
        var model: PsychoacousticModel
        var previousSlots = [[Double]](repeating: [Double](repeating: 0, count: 32), count: 18)
        var currentSlots: [[Double]]?
        var currentAttack = false
        var previousBlock = BlockType.normal
    }

    private struct GranuleSpectrum {
        var spectrum: [Double]
        var blockType: BlockType
    }

    public init(options: MP3EncoderOptions) throws {
        guard let tables = MP3Constants.tables(for: options.sampleRate) else {
            throw FormatError.unsupported("MP3 sample rate \(options.sampleRate)")
        }
        guard options.channels == 1 || options.channels == 2 else {
            throw FormatError.unsupported("MP3 with \(options.channels) channels")
        }
        if case .constant(let kilobits) = options.mode, !MP3EncoderOptions.constantBitrates.contains(kilobits) {
            throw FormatError.unsupported("MP3 bitrate \(kilobits) kbps")
        }
        if case .variable(let quality) = options.mode, !(0...9).contains(quality) {
            throw FormatError.unsupported("MP3 VBR quality \(quality)")
        }
        self.options = options
        self.tables = tables
        let cutoff = Self.cutoff(for: options.mode)
        cutoffLine = min(576, Int(cutoff / (Double(options.sampleRate) / 2) * 576))
        shortCutoffLine = min(192, Int(cutoff / (Double(options.sampleRate) / 2) * 192))
        let fullScale = Self.fullScaleEnergy()
        channels = (0..<options.channels).map { _ in
            ChannelState(
                model: PsychoacousticModel(sampleRate: options.sampleRate, tables: tables, fullScaleEnergy: fullScale)
            )
        }
        queued = [[Float]](repeating: [], count: options.channels)
        if case .variable = options.mode {
            let size = Self.xingFrameBytes(options)
            assembler.reserveXingFrame(size)
            streamBytes = size
        }
    }

    /// Low-pass that saves bits for audible bands.
    private static func cutoff(for mode: MP3EncoderOptions.Mode) -> Double {
        switch mode {
        case .constant(let kilobits):
            switch kilobits {
            case ..<192: 17_000
            case ..<256: 18_500
            case ..<320: 19_500
            default: 20_000
            }
        case .variable(let quality):
            19_500 - Double(quality) * 400
        }
    }

    /// Calibrates hearing threshold against full scale.
    private static func fullScaleEnergy() -> Double {
        var analysis = PolyphaseAnalysis()
        var previous = [[Double]](repeating: [Double](repeating: 0, count: 32), count: 18)
        var energy = 0.0
        let frequency = 1_000.0 / 44_100
        for granule in 0..<6 {
            var slots: [[Double]] = []
            for slot in 0..<18 {
                let start = (granule * 18 + slot) * 32
                let samples = (start..<(start + 32)).map { Float(sin(2 * Double.pi * frequency * Double($0))) }
                slots.append(analysis.analyze(samples))
            }
            let spectrum = HybridTransform.transform(previous: previous, current: slots, blockType: .normal)
            energy = spectrum.reduce(0) { $0 + $1 * $1 }
            previous = slots
        }
        return energy
    }

    private var queuedCount: Int { queued[0].count - queueStart }

    /// Interleaved samples; values outside [-1, 1] clip.
    public func encode(interleaved samples: [Float]) throws -> Data {
        guard !finished else { throw FormatError.encoderFailure("MP3 encoder already finished") }
        let count = options.channels
        guard samples.count % count == 0 else {
            throw FormatError.encoderFailure("interleaved samples must cover every channel")
        }
        for channel in 0..<count {
            queued[channel].append(
                contentsOf: stride(from: channel, to: samples.count, by: count).map { index in
                    let sample = samples[index]
                    return sample.isFinite ? min(max(sample, -1), 1) : 0
                }
            )
        }
        var output = Data()
        while queuedCount >= MP3Constants.granuleSize {
            try processGranule(output: &output)
        }
        if queueStart > Self.compactionThreshold {
            for channel in queued.indices { queued[channel].removeFirst(queueStart) }
            queueStart = 0
        }
        return output
    }

    public struct Finish {
        public let trailingBytes: Data
        /// Overwrites the first VBR frame.
        public let xingFrame: Data?
    }

    public func finish() throws -> Finish {
        guard !finished else { throw FormatError.encoderFailure("MP3 encoder already finished") }
        finished = true
        var output = Data()
        let granule = MP3Constants.granuleSize
        let remaining = queuedCount
        let padded = (remaining + granule - 1) / granule * granule + Self.flushGranules * granule
        for channel in queued.indices {
            queued[channel].append(contentsOf: [Float](repeating: 0, count: padded - remaining))
        }
        while queuedCount >= granule || !pendingGranules.isEmpty {
            if queuedCount < granule {
                for channel in queued.indices {
                    queued[channel].append(contentsOf: [Float](repeating: 0, count: granule))
                }
            }
            try processGranule(output: &output)
        }
        output.append(assembler.drain())
        let xing: Data? = if case .variable = options.mode { xingFrame() } else { nil }
        return Finish(trailingBytes: output, xingFrame: xing)
    }

    private func processGranule(output: inout Data) throws {
        let granule = MP3Constants.granuleSize
        var attacks: [Bool] = []
        var nextSlots: [[[Double]]] = []
        for channel in channels.indices {
            let samples = queued[channel][queueStart..<(queueStart + granule)]
            let delayed = channels[channel].detectorBacklog + samples
            attacks.append(channels[channel].detector.hasAttack(delayed.prefix(granule)))
            channels[channel].detectorBacklog = Array(delayed.suffix(Self.detectorDelay))
            var slots: [[Double]] = []
            for slot in 0..<18 {
                let start = samples.startIndex + slot * 32
                slots.append(channels[channel].analysis.analyze(samples[start..<(start + 32)]))
            }
            nextSlots.append(slots)
        }
        queueStart += granule
        let nextAttack = attacks.contains(true)
        if channels[0].currentSlots != nil {
            let blockType = Self.blockType(
                previous: channels[0].previousBlock, currentAttack: channels[0].currentAttack, nextAttack: nextAttack
            )
            var spectra: [GranuleSpectrum] = []
            for channel in channels.indices {
                guard let current = channels[channel].currentSlots else { continue }
                var spectrum = HybridTransform.transform(
                    previous: channels[channel].previousSlots, current: current, blockType: blockType
                )
                lowPass(&spectrum, blockType: blockType)
                spectra.append(GranuleSpectrum(spectrum: spectrum, blockType: blockType))
                channels[channel].previousSlots = current
                channels[channel].previousBlock = blockType
            }
            pendingGranules.append(spectra)
        }
        for channel in channels.indices {
            channels[channel].currentSlots = nextSlots[channel]
            channels[channel].currentAttack = nextAttack
        }
        if pendingGranules.count == 2 {
            output.append(try encodeFrame(pendingGranules))
            pendingGranules = []
        }
    }

    private static func blockType(previous: BlockType, currentAttack: Bool, nextAttack: Bool) -> BlockType {
        if previous == .start || currentAttack { return .short }
        if nextAttack { return previous == .short ? .short : .start }
        return previous == .short ? .stop : .normal
    }

    private func lowPass(_ spectrum: inout [Double], blockType: BlockType) {
        if blockType == .short {
            for window in 0..<3 {
                for line in shortCutoffLine..<192 {
                    spectrum[HybridTransform.shortIndex(line: line, window: window)] = 0
                }
            }
        } else {
            for line in cutoffLine..<576 { spectrum[line] = 0 }
        }
    }

    private func useMidSide(_ granules: [[GranuleSpectrum]]) -> Bool {
        guard options.channels == 2 else { return false }
        var side = 0.0
        var mid = 0.0
        for granule in granules {
            for (left, right) in zip(granule[0].spectrum, granule[1].spectrum) {
                side += (left - right) * (left - right)
                mid += (left + right) * (left + right)
            }
        }
        return mid > 0 && side < mid * Self.midSideRatio
    }

    private func encodeFrame(_ granules: [[GranuleSpectrum]]) throws -> Data {
        var granules = granules
        let midSide = useMidSide(granules)
        if midSide != previousMidSide {
            for channel in channels.indices { channels[channel].model.resetHistory() }
            previousMidSide = midSide
        }
        if midSide {
            let scale = 1 / 2.0.squareRoot()
            for granule in granules.indices {
                let left = granules[granule][0].spectrum
                let right = granules[granule][1].spectrum
                granules[granule][0].spectrum = zip(left, right).map { ($0 + $1) * scale }
                granules[granule][1].spectrum = zip(left, right).map { ($0 - $1) * scale }
            }
        }
        let quality: Double
        if case .variable(let level) = options.mode {
            quality = pow(10, (Double(level) * Self.qualityStepDecibels - Self.bestQualityDecibels) / 10)
        } else {
            quality = 1
        }
        var allowed: [[[Double]]] = []
        for granule in granules {
            allowed.append(
                granule.enumerated().map { channel, spectrum in
                    channels[channel].model.allowedNoise(
                        spectrum.spectrum, blockType: spectrum.blockType, quality: quality)
                }
            )
        }
        let quantizers = granules.indices.map { granule in
            granules[granule].indices.map { channel in
                GranuleQuantizer(
                    spectrum: granules[granule][channel].spectrum, blockType: granules[granule][channel].blockType,
                    tables: tables, allowedNoise: allowed[granule][channel]
                )
            }
        }
        switch options.mode {
        case .constant(let kilobits):
            guard let bitrateIndex = MP3Constants.bitrates.firstIndex(of: kilobits) else {
                throw FormatError.unsupported("MP3 bitrate \(kilobits) kbps")
            }
            let results = try encodeConstant(
                quantizers, granules: granules, allowed: allowed, bitrateIndex: bitrateIndex)
            return try assemble(results, bitrateIndex: bitrateIndex, midSide: midSide)
        case .variable:
            let available = assembler.reservoirBytes * 8
            let candidates = try quantizers.map { row in try row.map { try $0.encodeForQuality() } }
            let needed = candidates.joined().reduce(0) { $0 + $1.totalBits } + Self.alignmentSlack
            if let fitting = (1..<MP3Constants.bitrates.count).first(where: { index in
                nextSlot(bitrateIndex: index).bytes * 8 + available >= needed
            }) {
                return try assemble(candidates, bitrateIndex: fitting, midSide: midSide)
            }
            let largest = MP3Constants.bitrates.count - 1
            let results = try encodeConstant(quantizers, granules: granules, allowed: allowed, bitrateIndex: largest)
            return try assemble(results, bitrateIndex: largest, midSide: midSide)
        }
    }

    private func encodeConstant(
        _ quantizers: [[GranuleQuantizer]],
        granules: [[GranuleSpectrum]],
        allowed: [[[Double]]],
        bitrateIndex: Int
    ) throws -> [[GranuleQuantizer.Result]] {
        let slotBits = nextSlot(bitrateIndex: bitrateIndex).bytes * 8 - Self.alignmentSlack
        let base = slotBits / (2 * options.channels)
        var reservoir = assembler.reservoirBytes * 8
        return try quantizers.indices.map { granule in
            let shares = (2 - granule) * options.channels
            let budgets = quantizers[granule].indices.map { channel in
                let spectrum = granules[granule][channel]
                let demand = perceptualEntropy(
                    spectrum.spectrum, allowed: allowed[granule][channel], blockType: spectrum.blockType
                )
                return Self.budget(
                    base: base, demand: demand, reservoir: reservoir, shares: shares,
                    short: spectrum.blockType == .short
                )
            }
            let results = try zip(quantizers[granule], budgets).map { try $0.encode(budget: $1) }
            reservoir += results.reduce(0) { $0 + base - $1.totalBits }
            return results
        }
    }

    private static func budget(base: Int, demand: Int, reservoir: Int, shares: Int, short: Bool) -> Int {
        let reservoirShare = max(0, reservoir) / max(shares, 1)
        if short || demand > base {
            return base + min(reservoirShare, max(demand - base, short ? reservoirShare : 0))
        }
        return max(Int(Double(base) * lowDemandShare), min(base, demand))
    }

    /// Bits estimated for transparent coding.
    private func perceptualEntropy(_ spectrum: [Double], allowed: [Double], blockType: BlockType) -> Int {
        var entropy = 0.0
        if blockType == .short {
            for band in 0..<12 {
                for window in 0..<3 {
                    let lines = tables.shortBands[band]..<tables.shortBands[band + 1]
                    let energy = lines.reduce(0.0) { sum, line in
                        let value = spectrum[HybridTransform.shortIndex(line: line, window: window)]
                        return sum + value * value
                    }
                    entropy += Double(lines.count) * log2(1 + energy / max(allowed[band * 3 + window], 1e-20))
                }
            }
        } else {
            for band in 0..<21 {
                let lines = tables.longBands[band]..<tables.longBands[band + 1]
                let energy = lines.reduce(0.0) { $0 + spectrum[$1] * spectrum[$1] }
                entropy += Double(lines.count) * log2(1 + energy / max(allowed[band], 1e-20))
            }
        }
        return Int(entropy * Self.entropyToBits)
    }

    /// Next frame's slot size and padding.
    private func nextSlot(bitrateIndex: Int) -> (bytes: Int, padding: Bool, remainder: Int) {
        let product = 144 * MP3Constants.bitrates[bitrateIndex] * 1000
        let remainder = paddingRemainder + product % options.sampleRate
        let padding = remainder >= options.sampleRate
        let frameBytes = product / options.sampleRate + (padding ? 1 : 0)
        return (frameBytes - 4 - sideInfoBytes, padding, padding ? remainder - options.sampleRate : remainder)
    }

    private var sideInfoBytes: Int { options.channels == 1 ? 17 : 32 }

    private func assemble(_ results: [[GranuleQuantizer.Result]], bitrateIndex: Int, midSide: Bool) throws -> Data {
        let slot = nextSlot(bitrateIndex: bitrateIndex)
        var main = MSBBitWriter()
        var sides = results.map { $0.map(\.side) }
        for granule in results.indices {
            for channel in results[granule].indices {
                let result = results[granule][channel]
                let start = main.bitCount
                GranuleQuantizer.writeScalefactors(result, into: &main)
                MP3Huffman.write(
                    result.lines, plan: result.plan, longBands: tables.longBands,
                    windowSwitching: result.side.blockType != .normal, into: &main
                )
                let length = main.bitCount - start
                guard length <= Self.maximumPart23 else {
                    throw FormatError.encoderFailure("granule exceeds \(Self.maximumPart23) bits")
                }
                sides[granule][channel].part23Length = length
            }
        }
        let mainBytes = main.alignedBytes()
        let mainDataBegin = assembler.reservoirBytes
        guard mainBytes.count <= mainDataBegin + slot.bytes else {
            throw FormatError.encoderFailure("granule bits exceed the frame and reservoir")
        }
        paddingRemainder = slot.remainder
        var header = MSBBitWriter()
        header.write(0xFFF, bits: 12)
        header.write(1, bits: 1)
        header.write(1, bits: 2)
        header.write(1, bits: 1)
        header.write(UInt32(bitrateIndex), bits: 4)
        header.write(tables.frequencyIndex, bits: 2)
        header.write(slot.padding ? 1 : 0, bits: 1)
        header.write(0, bits: 1)
        header.write(options.channels == 1 ? 3 : 1, bits: 2)
        header.write(midSide ? 2 : 0, bits: 2)
        header.write(0, bits: 1)
        header.write(1, bits: 1)
        header.write(0, bits: 2)
        writeSideInfo(sides, mainDataBegin: mainDataBegin, into: &header)
        let headerBytes = header.alignedBytes()
        frameStarts.append(streamBytes)
        streamBytes += headerBytes.count + slot.bytes
        return assembler.add(
            header: headerBytes, slotBytes: slot.bytes, mainData: mainBytes,
            maximumReservoir: Self.maximumReservoirBytes
        )
    }

    private func writeSideInfo(_ sides: [[GranuleSide]], mainDataBegin: Int, into writer: inout MSBBitWriter) {
        writer.write(UInt32(mainDataBegin), bits: 9)
        writer.write(0, bits: options.channels == 1 ? 5 : 3)
        writer.write(0, bits: 4 * options.channels)
        for granule in sides {
            for side in granule {
                writer.write(UInt32(side.part23Length), bits: 12)
                writer.write(UInt32(side.bigValues), bits: 9)
                writer.write(UInt32(side.globalGain), bits: 8)
                writer.write(UInt32(side.scalefacCompress), bits: 4)
                let switching = side.blockType != .normal
                writer.write(switching ? 1 : 0, bits: 1)
                if switching {
                    writer.write(UInt32(side.blockType.rawValue), bits: 2)
                    writer.write(0, bits: 1)
                    writer.write(UInt32(side.tableSelect[0]), bits: 5)
                    writer.write(UInt32(side.tableSelect[1]), bits: 5)
                    writer.write(0, bits: 9)
                } else {
                    for region in 0..<3 { writer.write(UInt32(side.tableSelect[region]), bits: 5) }
                    writer.write(UInt32(side.region0Count), bits: 4)
                    writer.write(UInt32(side.region1Count), bits: 3)
                }
                writer.write(side.preflag ? 1 : 0, bits: 1)
                writer.write(side.scalefacScale ? 1 : 0, bits: 1)
                writer.write(side.count1TableB ? 1 : 0, bits: 1)
            }
        }
    }

    private static func xingFrameBytes(_ options: MP3EncoderOptions) -> Int {
        144 * MP3Constants.bitrates[xingBitrateIndex] * 1000 / options.sampleRate
    }

    private func xingFrame() -> Data {
        let size = Self.xingFrameBytes(options)
        var writer = MSBBitWriter()
        writer.write(0xFFFB, bits: 16)
        writer.write(UInt32(Self.xingBitrateIndex), bits: 4)
        writer.write(tables.frequencyIndex, bits: 2)
        writer.write(0, bits: 2)
        writer.write(options.channels == 1 ? 3 : 1, bits: 2)
        writer.write(0, bits: 2)
        writer.write(0, bits: 1)
        writer.write(1, bits: 1)
        writer.write(0, bits: 2)
        var frame = writer.alignedBytes()
        frame += [UInt8](repeating: 0, count: sideInfoBytes)
        frame += Array("Xing".utf8)
        frame += [0, 0, 0, 0x07]
        frame += bigEndian(UInt32(frameStarts.count))
        frame += bigEndian(UInt32(streamBytes))
        let total = max(streamBytes, 1)
        for percent in 0..<100 {
            let index = min(frameStarts.count * percent / 100, frameStarts.count - 1)
            let offset = index >= 0 ? frameStarts[index] : 0
            frame.append(UInt8(min(255, offset * 256 / total)))
        }
        frame += [UInt8](repeating: 0, count: max(0, size - frame.count))
        return Data(frame.prefix(size))
    }

    private func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }
}

/// Fills reservoir holes, then the slot.
private struct FrameAssembler {
    private var pending: [UInt8] = []
    private var holes: [Int] = []

    var reservoirBytes: Int { holes.count }

    mutating func reserveXingFrame(_ size: Int) {
        pending += [UInt8](repeating: 0, count: size)
    }

    mutating func add(header: [UInt8], slotBytes: Int, mainData: [UInt8], maximumReservoir: Int) -> Data {
        var remaining = mainData[...]
        for hole in holes {
            guard let byte = remaining.first else { break }
            pending[hole] = byte
            remaining = remaining.dropFirst()
        }
        holes.removeFirst(min(holes.count, mainData.count))
        pending += header
        let slotStart = pending.count
        pending += remaining
        pending += [UInt8](repeating: 0, count: slotBytes - remaining.count)
        holes += Array((slotStart + remaining.count)..<(slotStart + slotBytes))
        if holes.count > maximumReservoir { holes.removeFirst(holes.count - maximumReservoir) }
        let ready = holes.first ?? pending.count
        let output = Data(pending[..<ready])
        pending.removeFirst(ready)
        holes = holes.map { $0 - ready }
        return output
    }

    mutating func drain() -> Data {
        defer {
            pending = []
            holes = []
        }
        return Data(pending)
    }
}
