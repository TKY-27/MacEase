import AVFoundation
import CoreGraphics
import Engine
import Foundation
import ImageIO
import MenuCatalog
import UniformTypeIdentifiers

/// SPEC section 16 targets.
enum Targets {
    static let menuSeconds = 0.030
    static let heicSeconds = 0.5
    static let videoSeconds = 30.0
    static let menuItems = 1_000
    static let transportPaths = 5_000
    static let photoWidth = 4_000
    static let photoHeight = 3_000
    static let clipWidth = 1_920
    static let clipHeight = 1_080
    static let clipSeconds = 60
    static let clipFrameRate: Int32 = 30
    static let clipBitrate = 15_000_000
}

let labelWidth = 36

struct BenchError: Error, CustomStringConvertible {
    let description: String
}

func measure(_ label: String, target: Double, _ body: () async throws -> Void) async throws {
    let start = ContinuousClock.now
    try await body()
    let seconds = (ContinuousClock.now - start) / .seconds(1)
    let verdict = seconds <= target ? "ok" : "SLOW"
    let column = label.padding(toLength: labelWidth, withPad: " ", startingAt: 0)
    print(column + String(format: "%8.3f s   target %7.3f s   ", seconds, target) + verdict)
    fflush(stdout)
}

/// Keeps trashed originals off the user's Trash.
func scratchVolume() throws -> URL {
    let base = FileManager.default.temporaryDirectory.appending(path: "MacEaseBench-\(UUID().uuidString)")
    let mount = base.appending(path: "mnt")
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    let image = base.appending(path: "bench.sparseimage")
    try hdiutil(["create", "-size", "4g", "-fs", "APFS", "-type", "SPARSE", "-volname", "MacEaseBench", image.path])
    try hdiutil(["attach", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, image.path])
    return mount
}

func hdiutil(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw BenchError(description: "hdiutil \(arguments[0]) failed") }
}

func run(_ op: OperationID, preset: String, on url: URL) async throws {
    let settings = Settings()
    guard let options = OperationPlanner.options(for: op, preset: preset, settings: settings) else {
        throw BenchError(description: "\(op.rawValue) has no preset \(preset)")
    }
    let support = FileManager.default.temporaryDirectory.appending(path: "MacEaseBenchSupport-\(UUID().uuidString)")
    let engine = try JobEngine(supportDirectory: support, concurrency: 1)
    let batch = OperationPlanner.batch(
        for: OperationRequest(op: op, options: options, inputs: [url]), settings: settings)
    let outcome = await engine.run(batch, settings: settings) { _ in }
    guard case .succeeded = outcome.outcomes.first else {
        throw BenchError(description: "\(op.rawValue) did not succeed: \(String(describing: outcome.outcomes.first))")
    }
}

func writePhoto(to url: URL) throws {
    guard
        let context = CGContext(
            data: nil, width: Targets.photoWidth, height: Targets.photoHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw BenchError(description: "no drawing context") }
    for band in 0..<Targets.photoHeight / 10 {
        let shade = CGFloat(band % 97) / 97
        context.setFillColor(CGColor(red: shade, green: 1 - shade, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: band * 10, width: Targets.photoWidth, height: 10))
    }
    guard let image = context.makeImage(),
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil)
    else { throw BenchError(description: "HEIC encoding unavailable") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw BenchError(description: "HEIC write failed") }
}

func writeClip(to url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let video = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Targets.clipWidth,
            AVVideoHeightKey: Targets.clipHeight,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Targets.clipBitrate],
        ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: video,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Targets.clipWidth, kCVPixelBufferHeightKey as String: Targets.clipHeight,
        ])
    writer.add(video)
    guard writer.startWriting() else { throw BenchError(description: "clip writer did not start") }
    writer.startSession(atSourceTime: .zero)
    let frames = Targets.clipSeconds * Int(Targets.clipFrameRate)
    for index in 0..<frames {
        while !video.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
        guard let pool = adaptor.pixelBufferPool else { throw BenchError(description: "no pixel pool") }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw BenchError(description: "no pixel buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let count = CVPixelBufferGetBytesPerRow(buffer) * Targets.clipHeight
            for offset in stride(from: 0, to: count, by: 4) {
                bytes[offset] = UInt8(truncatingIfNeeded: offset &+ index * 7)
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(
            buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: Targets.clipFrameRate))
    }
    video.markAsFinished()
    await writer.finishWriting()
    if let error = writer.error { throw error }
}

func benchmark() async throws {
    let volume = try scratchVolume()
    defer { try? hdiutil(["detach", "-force", volume.path]) }

    let titles = MenuTitles(operation: { $0.rawValue }, preset: { $1 }, kind: { $0.rawValue })
    let menu = MenuFile(
        token: String(repeating: "0", count: 64), hostAvailable: true, visibleOperations: OperationID.allCases,
        titles: titles)
    let selection = (0..<Targets.menuItems).map { volume.appending(path: "photo-\($0).heic") }
    try await measure("Menu for \(Targets.menuItems) items", target: Targets.menuSeconds) {
        _ = MenuLayout.nodes(for: menu, selection: selection)
    }

    let paths = (0..<Targets.transportPaths).map { "/Users/someone/Pictures/photo-\($0).heic" }
    let request = RunRequest(catalogVersion: menu.catalogVersion, entryIndex: 0, token: menu.token, paths: paths)
    try await measure("Parse \(Targets.transportPaths) paths", target: Targets.menuSeconds) {
        guard let url = request.url(scheme: "macease"), try RunRequest(url: url, scheme: "macease") == request else {
            throw BenchError(description: "transport round trip failed")
        }
    }

    let photo = volume.appending(path: "photo.heic")
    try writePhoto(to: photo)
    try await measure("12 MP HEIC to JPEG", target: Targets.heicSeconds) {
        try await run(.imageConvert, preset: "jpeg", on: photo)
    }

    let clip = volume.appending(path: "clip.mp4")
    try await writeClip(to: clip)
    try await measure("60 s 1080p to 20 MB (Discord)", target: Targets.videoSeconds) {
        try await run(.videoCompress, preset: "discord", on: clip)
    }
}

do {
    try await benchmark()
} catch {
    print("Benchmark stopped: \(error)")
    exit(1)
}
