import CoreGraphics
import Formats
import Foundation
import MenuCatalog
import PDFKit
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import Engine

struct ActivitySessionTests {
    @Test func retriesOnlyFailuresAndReservesUntilCompletion() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let names = ["success", "failed", "skipped", "cancelled"]
        let inputs = try names.map { name in
            try ImageFixtures.write(
                [ImageFixtures.photo(width: 32, height: 24)], as: .png,
                to: folder.appending(path: "\(name).png"))
        }
        let work = inputs.enumerated().map { index, input in
            WorkItem(inputs: [input]) { context in
                switch index {
                case 0:
                    let staged = try context.stagingURL(for: input, name: "successful.txt")
                    try Data("Already completed".utf8).write(to: staged)
                    return .derived(
                        nextTo: input, outputs: [StagedFile(url: staged, name: "successful.txt", check: .text(.utf8))])
                case 1: throw EngineError.encodeFailed("Fixture failure")
                case 2: return .skipped(.changedSinceScan)
                default: throw CancellationError()
                }
            }
        }
        let engine = try JobEngine(supportDirectory: folder.appending(path: "support"), concurrency: 2)
        var settings = Settings()
        settings.outputMode = .newFile
        let request = OperationRequest(
            op: .imageConvert, options: .image(.convert(ImageConversion(format: .jpeg))), inputs: inputs)
        let outcome = await engine.run(Batch(operation: .imageConvert, items: work), settings: settings) { _ in }
        var session = ActivitySession(request: request, settings: settings, outcome: outcome)
        #expect(session.failedIndices == [1])
        let retry = try session.beginRetry()
        #expect(retry.inputs == [inputs[1]])
        #expect(retry.options == request.options)
        #expect(!session.canRetry)
        #expect(throws: ActivityAvailability.unavailable) { try session.beginRetry() }
        let retried = await engine.run(session.retryBatch(for: retry), settings: session.settings) { _ in }
        #expect(retried.outcomes.count == 1)
        guard case .succeeded(let outputs, _) = retried.outcomes[0] else {
            Issue.record("The failed file was not retried")
            return
        }
        #expect(outputs.first?.pathExtension == "jpg")
        #expect(
            try String(contentsOf: folder.appending(path: "successful.txt"), encoding: .utf8) == "Already completed")
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "success.jpg").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "skipped.jpg").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "cancelled.jpg").path))
        session.endRetry()
        #expect(session.canRetry)
    }

    @Test(arguments: ["missing", "changed", "identity"])
    func retryRejectsUnavailableOrReplacedInputs(_ change: String) async throws {
        let fixture = try await failedImage()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: fixture.folder) } }
        var session = fixture.session
        let original = try Data(contentsOf: fixture.input)
        let modified = try fixture.input.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if change == "missing" {
            try FileManager.default.removeItem(at: fixture.input)
            #expect(throws: ActivityAvailability.missing(fixture.input.lastPathComponent)) { try session.beginRetry() }
        } else {
            if change == "identity" {
                try original.write(to: fixture.input, options: .atomic)
                if let modified {
                    try FileManager.default.setAttributes(
                        [.modificationDate: modified], ofItemAtPath: fixture.input.path)
                }
            } else {
                try Data("Changed contents".utf8).write(to: fixture.input)
            }
            #expect(throws: ActivityAvailability.changed(fixture.input.lastPathComponent)) { try session.beginRetry() }
        }
        #expect(session.canRetry)
    }

    @Test(arguments: ["changed", "missing"])
    func retryChecksAgainAtExecutionAndKeepsOriginalStamp(_ change: String) async throws {
        let fixture = try await failedImage()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: fixture.folder) } }
        var session = fixture.session
        let retry = try session.beginRetry()
        let expected: EngineError
        if change == "missing" {
            try FileManager.default.removeItem(at: fixture.input)
            expected = .retryInputMissing
        } else {
            try Data("Changed after opening retry".utf8).write(to: fixture.input)
            expected = .retryInputChanged
        }
        let outcome = await fixture.engine.run(session.retryBatch(for: retry), settings: session.settings) { _ in }
        #expect(outcome.outcomes == [.failed(expected)])
        #expect(outcome.record == nil)
        var next = ActivitySession(request: retry, settings: session.settings, outcome: outcome)
        if change == "missing" {
            #expect(!FileManager.default.fileExists(atPath: fixture.input.path))
            #expect(throws: ActivityAvailability.missing(fixture.input.lastPathComponent)) { try next.beginRetry() }
        } else {
            #expect(try String(contentsOf: fixture.input, encoding: .utf8) == "Changed after opening retry")
            #expect(throws: ActivityAvailability.changed(fixture.input.lastPathComponent)) { try next.beginRetry() }
        }
    }

    @Test(arguments: [ImageFormat.ico, .icns, .gif])
    func conversionDetailsMatchDecodedOutput(_ format: ImageFormat) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = try ImageFixtures.write(
            [ImageFixtures.photo(width: 400, height: 300)], as: .png,
            to: folder.appending(path: "photo.png"))
        let engine = try JobEngine(supportDirectory: folder.appending(path: "support"), concurrency: 1)
        let settings = Settings()
        let request = OperationRequest(
            op: .imageConvert, options: .image(.convert(ImageConversion(format: format))), inputs: [input])
        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: settings), settings: settings) {
            _ in
        }
        let output = try ImageFixtures.output(of: outcome)
        let decoded = try await ImageDocument.load(output)
        let details = try #require(outcome.details.first?.image)
        let expectedWidth = format == .ico ? 256 : format == .icns ? 1024 : 400
        let expectedHeight = format == .ico ? 256 : format == .icns ? 1024 : 300
        #expect(decoded.first.width == expectedWidth)
        #expect(decoded.first.height == expectedHeight)
        #expect(details.originalWidth == 400 && details.originalHeight == 300)
        #expect(details.outputWidth == expectedWidth && details.outputHeight == expectedHeight)
        #expect(details.reducedDimensions == (format == .ico))
        #expect(details.quantized == (format == .gif))
        #expect(details.paletteColors == (format == .gif ? 256 : nil))
    }

    @Test(arguments: [UTType.png, .jpeg])
    func imageToPDFSucceedsWithoutOfferingImageComparison(_ inputType: UTType) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = try ImageFixtures.write(
            [ImageFixtures.photo(width: 64, height: 48)], as: inputType,
            to: folder.appending(path: inputType == .png ? "source.png" : "source.jpg"))
        let original = try Data(contentsOf: input)
        let engine = try JobEngine(supportDirectory: folder.appending(path: "support"), concurrency: 1)
        let settings = Settings()
        let request = OperationRequest(
            op: .imageConvert, options: .image(.convert(ImageConversion(format: .pdf))), inputs: [input])
        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: settings), settings: settings) {
            _ in
        }
        let output = try ImageFixtures.output(of: outcome)
        #expect(PDFDocument(url: output)?.pageCount == 1)
        #expect(try Data(contentsOf: input) == original)
        let session = ActivitySession(request: request, settings: settings, outcome: outcome)
        #expect(!session.supportsComparison)
        #expect(session.comparisonIndices.isEmpty)
    }

    @Test(arguments: [false, true])
    func staticGIFCompressionReportsAcceptedPaletteAndAllowsComparison(_ targetSize: Bool) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let source = folder.appending(path: "palette.gif")
        let frame = ImageFrame(image: try ImageFixtures.photo(width: 160, height: 120), duration: 0)
        let original = try ImageEncoder.encode([frame], as: .gif, options: EncodeOptions(quality: 100))
        try original.write(to: source)
        let decoded = try await ImageDocument.load(source)
        var reduced = ImageOutput.defaultOptions(for: decoded, format: .gif, settings: Settings().image)
        let unchanged = try ImageEncoder.encode(decoded.frames, as: .gif, options: reduced)
        reduced.gifColors = 64
        let fitting = try ImageEncoder.encode(decoded.frames, as: .gif, options: reduced)
        let target = Int64(fitting.count)
        try #require(fitting.count < original.count && fitting.count < unchanged.count)
        let compression = ImageCompression(
            goal: targetSize ? .bytes(target) : .level(.low),
            allowsDownscale: false, allowsFrameRateReduction: false, stripsGPS: false)
        let request = OperationRequest(op: .imageCompress, options: .image(.compress(compression)), inputs: [source])
        let settings = Settings()
        let engine = try JobEngine(supportDirectory: folder.appending(path: "support"), concurrency: 1)
        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: settings), settings: settings) {
            _ in
        }
        let output = try ImageFixtures.output(of: outcome)
        let image = try await ImageDocument.load(output)
        let details = try #require(outcome.details.first?.image)
        if targetSize { #expect(try Data(contentsOf: output).count <= target) }
        #expect(image.first.width == 160 && image.first.height == 120)
        #expect(details.outputWidth == 160 && details.outputHeight == 120)
        #expect(details.frameCount == 1 && !details.isMultiPage)
        #expect(details.quantized)
        #expect(!details.reducedDimensions)
        #expect(try colorCount(image.first) < colorCount(decoded.first))
        let palette = try #require(details.paletteColors)
        guard case .succeeded(_, let warnings) = try #require(outcome.outcomes.first) else { return }
        #expect(warnings.contains(.imagePaletteReduced(colors: palette)))
        let session = ActivitySession(request: request, settings: settings, outcome: outcome)
        #expect(session.comparisonIndices == [0])
        #expect(try session.comparison(at: 0).output == output)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func animatedGIFReportsSelectedPaletteReduction() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let source = folder.appending(path: "animated.gif")
        let frames = try [1, 2].map { seed in
            ImageFrame(image: try ImageFixtures.photo(width: 96, height: 64, seed: seed), duration: 0.1)
        }
        let original = try ImageEncoder.encode(frames, as: .gif, options: EncodeOptions(quality: 100))
        try original.write(to: source)
        let decoded = try await ImageDocument.load(source)
        var options = ImageOutput.defaultOptions(for: decoded, format: .gif, settings: Settings().image)
        let calibration = folder.appending(path: "calibration.gif")
        try await ImageEncoder.encodeStreaming(
            frameCount: decoded.frameCount, as: .gif, options: options, to: calibration
        ) {
            try decoded.frame(at: $0)
        }
        let unchanged = try Data(contentsOf: calibration).count
        options.gifColors = 64
        try FileManager.default.removeItem(at: calibration)
        try await ImageEncoder.encodeStreaming(
            frameCount: decoded.frameCount, as: .gif, options: options, to: calibration
        ) {
            try decoded.frame(at: $0)
        }
        let target = Int64(try Data(contentsOf: calibration).count)
        try #require(target < original.count && target < unchanged)
        let compression = ImageCompression(
            goal: .bytes(target), allowsDownscale: false,
            allowsFrameRateReduction: false, stripsGPS: false)
        let request = OperationRequest(op: .imageCompress, options: .image(.compress(compression)), inputs: [source])
        let settings = Settings()
        let engine = try JobEngine(supportDirectory: folder.appending(path: "support"), concurrency: 1)
        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: settings), settings: settings) {
            _ in
        }
        let output = try ImageFixtures.output(of: outcome)
        let image = try await ImageDocument.load(output)
        let details = try #require(outcome.details.first?.image)
        #expect(try Data(contentsOf: output).count <= target)
        #expect(image.frameCount == 2)
        #expect(image.first.width == 96 && image.first.height == 64)
        #expect(details.outputWidth == 96 && details.outputHeight == 64)
        #expect(details.frameCount == 2)
        #expect(details.quantized && details.paletteColors == 64)
        #expect(try colorCount(image.first) < colorCount(decoded.first))
        let session = ActivitySession(request: request, settings: settings, outcome: outcome)
        #expect(session.comparisonIndices.isEmpty)
    }

    @Test func GIFReductionCallbackKeepsAnAlreadySmallPalette() throws {
        let image = try ImageFixtures.canvas(width: 16, height: 16) { canvas in
            canvas.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            canvas.fill(CGRect(x: 8, y: 0, width: 8, height: 16))
        }
        var options = EncodeOptions(quality: 100)
        options.gifColors = 64
        var reductions: [Bool] = []
        options.reportGIFReduction = { reductions.append($0) }
        let frame = ImageFrame(image: image, duration: 0.1)
        let encoded = try ImageEncoder.encode([frame, frame], as: .gif, options: options)
        #expect(reductions == [false, false])
        let decoded = try ImageDocument.load(bytes: encoded, url: URL(fileURLWithPath: "/palette.gif"))
        #expect(decoded.frameCount == 2)
        #expect(try colorCount(decoded.first) == 2)
    }

    @Test(arguments: [ImageFormat.ico, .icns])
    func iconCompressionReportsActualEncodedDimensions(_ format: ImageFormat) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let frame = ImageFrame(image: try ImageFixtures.photo(width: 256, height: 256), duration: 0)
        let original = try ImageEncoder.encode([frame], as: format, options: EncodeOptions(quality: 100))
        let source = folder.appending(path: "icon.\(format.fileExtension)")
        try original.write(to: source)
        let originalImage = try await ImageDocument.load(source)
        let target = Int64(original.count) * 9 / 10
        let compression = ImageCompression(
            goal: .bytes(target), allowsDownscale: true,
            allowsFrameRateReduction: false, stripsGPS: false)
        let request = OperationRequest(op: .imageCompress, options: .image(.compress(compression)), inputs: [source])
        let settings = Settings()
        let engine = try JobEngine(supportDirectory: folder.appending(path: "support"), concurrency: 1)
        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: settings), settings: settings) {
            _ in
        }
        let output = try ImageFixtures.output(of: outcome)
        let image = try await ImageDocument.load(output)
        let details = try #require(outcome.details.first?.image)
        let expected = format == .ico ? 128 : 1024
        #expect(try Data(contentsOf: output).count <= target)
        #expect(image.first.width == expected && image.first.height == expected)
        #expect(details.outputWidth == expected && details.outputHeight == expected)
        #expect(details.reducedDimensions == (expected < originalImage.first.width))
        #expect(!details.quantized)
        #expect(try Data(contentsOf: source) == original)
    }

    private func colorCount(_ image: CGImage) throws -> Int {
        let rgba = try PixelBuffer(cgImage: image).rgba
        var colors = Set<UInt32>()
        for offset in stride(from: 0, to: rgba.count, by: 4) {
            let upper = UInt32(rgba[offset]) << 24 | UInt32(rgba[offset + 1]) << 16
            let lower = UInt32(rgba[offset + 2]) << 8 | UInt32(rgba[offset + 3])
            colors.insert(upper | lower)
        }
        return colors.count
    }

    @Test func retryEligibilityExcludesOtherOperationsAndCancellation() async throws {
        let fixture = try await failedImage()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: fixture.folder) } }
        let allowed: Set<OperationID> = [
            .imageCompress, .imageConvert, .videoCompress, .videoConvert,
            .audioCompress, .audioConvert, .pdfCompress,
        ]
        for operation in OperationID.allCases {
            let request = OperationRequest(
                op: operation, options: fixture.session.request.options, inputs: [fixture.input])
            let session = ActivitySession(request: request, settings: Settings(), outcome: fixture.session.outcome)
            #expect(session.canRetry == allowed.contains(operation))
        }
        let original = fixture.session.outcome
        let cancelled = BatchOutcome(
            batchID: UUID(), operation: .imageConvert, inputs: original.inputs,
            outcomes: [.failed(.cancelled)], clipboardText: nil, reportText: nil, record: nil,
            historyFailed: false, details: original.details)
        let session = ActivitySession(request: fixture.session.request, settings: Settings(), outcome: cancelled)
        #expect(!session.canRetry)
        #expect(session.comparisonIndices.isEmpty)
    }

    @Test func comparisonUsesRecordedTrashAndRejectsChangedOutput() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = folder.appending(path: "original.png")
        let output = folder.appending(path: "output.png")
        let trash = folder.appending(path: "recorded-trash.png")
        try Data("Original bytes".utf8).write(to: trash)
        try Data("Output".utf8).write(to: output)
        let originalStamp = try FileStamp(of: trash, includingIdentity: true)
        let outputStamp = try FileStamp(of: output, includingIdentity: true)
        let batchID = UUID()
        let outcome = BatchOutcome(
            batchID: batchID, operation: .imageCompress, inputs: [[input]],
            outcomes: [.succeeded(outputs: [output], warnings: [])], clipboardText: nil, reportText: nil,
            record: BatchRecord(
                id: batchID, operation: .imageCompress, date: Date(),
                items: [
                    .replaced(
                        original: input.path, trashed: trash.path, output: output.path,
                        stamp: outputStamp, trashStamp: originalStamp)
                ], undone: false), historyFailed: false,
            details: [
                ItemDetails(
                    inputStamps: [input: originalStamp], outputStamps: [output: outputStamp],
                    image: ImageResultDetails(
                        originalWidth: 32, originalHeight: 24, outputWidth: 16, outputHeight: 12,
                        reducedDimensions: true, quantized: false, paletteColors: nil, frameCount: 1, isMultiPage: false
                    ))
            ])
        let request = OperationRequest(
            op: .imageCompress,
            options: .image(
                .compress(
                    ImageCompression(
                        goal: .bytes(1000), allowsDownscale: false, allowsFrameRateReduction: false, stripsGPS: false))),
            inputs: [input])
        let session = ActivitySession(request: request, settings: Settings(), outcome: outcome)
        let comparison = try session.comparison(at: 0)
        #expect(comparison.original == trash)
        #expect(comparison.output == output)
        #expect(comparison.details.originalBytes == 14)
        #expect(comparison.details.outputBytes == 6)
        try Data("New output".utf8).write(to: output)
        #expect(throws: ActivityAvailability.changed(output.lastPathComponent)) { try session.comparison(at: 0) }
        try FileManager.default.removeItem(at: trash)
        #expect(throws: ActivityAvailability.missing(trash.lastPathComponent)) { try session.comparison(at: 0) }
    }

    @Test func progressAndResultDescribeRealCommittedOutput() async throws {
        let fixture = try await failedImage()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: fixture.folder) } }
        let updates = Mutex<[BatchProgress]>([])
        let work = WorkItem(inputs: [fixture.input]) { context in
            context.phase(.decoding)
            context.progress(1)
            context.reportImageResult(
                originalWidth: 32, originalHeight: 24, outputWidth: 16, outputHeight: 12,
                reducedDimensions: true, quantized: true, paletteColors: 16)
            let staged = try context.stagingURL(for: fixture.input, name: "measured.txt")
            try Data(repeating: 65, count: 100_000).write(to: staged)
            return .derived(
                nextTo: fixture.input, outputs: [StagedFile(url: staged, name: "measured.txt", check: .text(.utf8))])
        }
        let outcome = await fixture.engine.run(Batch(operation: .imageConvert, items: [work]), settings: Settings()) {
            update in
            updates.withLock { $0.append(update) }
        }
        let details = try #require(outcome.details.first)
        #expect(details.originalBytes == Int64(try Data(contentsOf: fixture.input).count))
        #expect(details.outputBytes == 100_000)
        #expect(details.elapsedSeconds > 0)
        #expect(details.image?.reducedDimensions == true)
        #expect(details.image?.paletteColors == 16)
        #expect(details.outputBytes > details.originalBytes)
        let progress = updates.withLock { $0 }
        #expect(progress.contains { $0.itemPhases == [.decoding] })
        #expect(progress.contains { $0.itemPhases == [.saving] })
        #expect(progress.last?.fraction == 1)
        #expect(progress.filter { $0.itemPhases != [.finished] }.allSatisfy { $0.fraction < 1 })
    }

    @Test func comparisonRendersBoundedNativePixelCropAndRefusesMultipage() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let frame = try ImageFixtures.canvas(width: 320, height: 240) { canvas in
            canvas.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            canvas.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
            canvas.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            canvas.fill(CGRect(x: 160, y: 0, width: 160, height: 240))
        }
        let input = try ImageFixtures.write([frame], as: .png, to: folder.appending(path: "still.png"))
        let preview = try await ActivityImagePreview.open(input, viewport: CGSize(width: 64, height: 48), scale: 1)
        #expect(preview.width == 320)
        #expect(preview.height == 240)
        #expect(preview.image.width == 64)
        #expect(preview.image.height == 48)
        #expect(preview.displaySize == CGSize(width: 64, height: 48))
        #expect(try ImageFixtures.pixel(preview.image, x: 0, y: 24) == [255, 0, 0, 255])
        #expect(try ImageFixtures.pixel(preview.image, x: 63, y: 24) == [0, 0, 255, 255])
        let pages = try ImageFixtures.write([frame, frame], as: .tiff, to: folder.appending(path: "pages.tiff"))
        await #expect(throws: ActivityAvailability.animatedOrMultipage) { try await ActivityImagePreview.open(pages) }
    }

    private func failedImage() async throws -> (folder: URL, input: URL, engine: JobEngine, session: ActivitySession) {
        let folder = try AudioSignals.temporaryFolder()
        let input = try ImageFixtures.write(
            [ImageFixtures.photo(width: 32, height: 24)], as: .png,
            to: folder.appending(path: "failed.png"))
        let engine = try JobEngine(supportDirectory: folder.appending(path: "support"), concurrency: 1)
        var settings = Settings()
        settings.outputMode = .newFile
        let request = OperationRequest(
            op: .imageConvert, options: .image(.convert(ImageConversion(format: .jpeg))), inputs: [input])
        let outcome = await engine.run(
            Batch(
                operation: .imageConvert,
                items: [
                    WorkItem(inputs: [input]) { _ in
                        throw EngineError.encodeFailed("Fixture failure")
                    }
                ]), settings: settings
        ) { _ in }
        return (folder, input, engine, ActivitySession(request: request, settings: settings, outcome: outcome))
    }
}
