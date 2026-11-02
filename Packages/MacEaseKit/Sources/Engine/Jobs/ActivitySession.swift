import CoreGraphics
import Foundation
import MenuCatalog

public enum ItemPhase: Int, Sendable {
    case queued, preparing, decoding, searching, encoding, optimizing, verifying, saving, finished
}

public struct ImageResultDetails: Sendable {
    public let originalWidth: Int
    public let originalHeight: Int
    public let outputWidth: Int
    public let outputHeight: Int
    public let reducedDimensions: Bool
    public let quantized: Bool
    public let paletteColors: Int?
    public let frameCount: Int
    public let isMultiPage: Bool
}

public struct ItemDetails: Sendable {
    public internal(set) var inputStamps: [URL: FileStamp] = [:]
    public internal(set) var outputStamps: [URL: FileStamp] = [:]
    public internal(set) var elapsedSeconds: Double = 0
    public internal(set) var image: ImageResultDetails?
    public var originalBytes: Int64 { inputStamps.values.compactMap(\.size).reduce(0, +) }
    public var outputBytes: Int64 { outputStamps.values.compactMap(\.size).reduce(0, +) }
}

public enum ActivityAvailability: Error, Equatable, Sendable {
    case unsupported
    case unavailable
    case missing(String)
    case changed(String)
    case animatedOrMultipage
}

public struct ActivityComparison: Sendable {
    public let original: URL
    public let output: URL
    public let originalStamp: FileStamp
    public let outputStamp: FileStamp
    public let details: ItemDetails

    public func validate() throws {
        try ActivitySession.validate(original, stamp: originalStamp)
        try ActivitySession.validate(output, stamp: outputStamp)
    }
}

public struct ActivitySession: Sendable {
    public let request: OperationRequest
    public let settings: Settings
    public let outcome: BatchOutcome
    private var retrying = false

    public init(request: OperationRequest, settings: Settings, outcome: BatchOutcome) {
        self.request = request
        self.settings = settings
        self.outcome = outcome
    }

    public var supportsRetry: Bool {
        [.imageCompress, .imageConvert, .videoCompress, .videoConvert, .audioCompress, .audioConvert, .pdfCompress]
            .contains(request.op)
    }

    public var failedIndices: [Int] {
        guard supportsRetry else { return [] }
        return outcome.outcomes.indices.filter {
            if case .failed(let error) = outcome.outcomes[$0] { return error != .cancelled }
            return false
        }
    }

    public var canRetry: Bool { !retrying && !failedIndices.isEmpty }

    public mutating func beginRetry(options: OperationOptions? = nil) throws -> OperationRequest {
        guard canRetry else { throw ActivityAvailability.unavailable }
        let inputs = try failedIndices.flatMap { index in
            try outcome.inputs[index].map { url in
                guard let stamp = outcome.details[index].inputStamps[url] else {
                    throw ActivityAvailability.unavailable
                }
                try Self.validate(url, stamp: stamp)
                return url
            }
        }
        retrying = true
        return OperationRequest(op: request.op, options: options ?? request.options, inputs: inputs)
    }

    public func retryBatch(for retry: OperationRequest) -> Batch {
        let planned = OperationPlanner.batch(for: retry, settings: settings)
        let checked = planned.items.map { work in
            guard retrying, retry.op == request.op else {
                return WorkItem(inputs: work.inputs) { _ in throw ActivityAvailability.unavailable }
            }
            var expected: [URL: FileStamp] = [:]
            for input in work.inputs {
                guard let index = failedIndices.first(where: { outcome.inputs[$0].contains(input) }),
                    let stamp = outcome.details[index].inputStamps[input]
                else {
                    return WorkItem(inputs: work.inputs) { _ in throw ActivityAvailability.unavailable }
                }
                expected[input] = stamp
            }
            var checked = work
            checked.requiredInputStamps = expected
            return checked
        }
        return Batch(operation: planned.operation, items: checked)
    }

    public mutating func endRetry() { retrying = false }

    public var supportsComparison: Bool {
        guard [.imageCompress, .imageConvert].contains(request.op) else { return false }
        if case .image(.convert(let conversion)) = request.options, conversion.format == .pdf { return false }
        return true
    }

    public var comparisonIndices: [Int] {
        guard supportsComparison else { return [] }
        return outcome.outcomes.indices.filter {
            if case .succeeded(let outputs, _) = outcome.outcomes[$0] {
                let image = outcome.details[$0].image
                return outputs.count == 1 && image?.frameCount == 1 && image?.isMultiPage != true
            }
            return false
        }
    }

    public func comparison(at index: Int) throws -> ActivityComparison {
        guard comparisonIndices.contains(index), outcome.inputs[index].count == 1,
            case .succeeded(let outputs, _) = outcome.outcomes[index], let output = outputs.first,
            let input = outcome.inputs[index].first,
            let inputStamp = outcome.details[index].inputStamps[input],
            let outputStamp = outcome.details[index].outputStamps[output]
        else { throw ActivityAvailability.unsupported }
        var original = input
        var originalStamp = inputStamp
        for record in outcome.record?.items ?? [] {
            if case .replaced(let path, let trashed, let destination, _, let trashStamp) = record,
                path == input.path, destination == output.path
            {
                guard let trashStamp else { throw ActivityAvailability.unavailable }
                original = URL(fileURLWithPath: trashed)
                originalStamp = trashStamp
            }
        }
        let comparison = ActivityComparison(
            original: original, output: output, originalStamp: originalStamp,
            outputStamp: outputStamp, details: outcome.details[index])
        try comparison.validate()
        return comparison
    }

    static func validate(_ url: URL, stamp: FileStamp) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ActivityAvailability.missing(url.lastPathComponent)
        }
        guard stamp.matchesIdentity(url.path) else { throw ActivityAvailability.changed(url.lastPathComponent) }
        try OperationPlanner.validateInput(url)
    }
}

public struct ActivityImagePreview: Sendable {
    private static let gate = LaneGate(width: 1)
    public let image: CGImage
    public let width: Int
    public let height: Int
    public let displaySize: CGSize?

    public static func open(
        _ url: URL, maximumDimension: Int = 2048, viewport: CGSize? = nil,
        scale: Double = 1, center: CGPoint = CGPoint(x: 0.5, y: 0.5)
    ) async throws -> ActivityImagePreview {
        try await gate.acquire()
        do {
            let preview = try await decode(
                url, maximumDimension: maximumDimension, viewport: viewport, scale: scale, center: center)
            await gate.release()
            return preview
        } catch {
            await gate.release()
            throw error
        }
    }

    private static func decode(
        _ url: URL, maximumDimension: Int, viewport: CGSize?, scale: Double, center: CGPoint
    ) async throws -> ActivityImagePreview {
        guard maximumDimension > 0, maximumDimension <= 2048, scale.isFinite, scale > 0,
            center.x.isFinite, center.y.isFinite
        else { throw EngineError.invalidInput(.invalidNumericParameter) }
        let document = try await ImageDocument.load(url)
        guard document.frameCount == 1, !document.isAnimated, !document.isMultiPage else {
            throw ActivityAvailability.animatedOrMultipage
        }
        let reference = document.containsHDRPixels ? try document.toneMappedToSDR() : document
        let source = reference.first
        let image: CGImage
        let displaySize: CGSize?
        if let viewport {
            guard viewport.width.isFinite, viewport.height.isFinite else {
                throw EngineError.invalidInput(.invalidNumericParameter)
            }
            let width = min(Double(source.width), max(1, min(Double(maximumDimension), viewport.width)) / scale)
            let height = min(Double(source.height), max(1, min(Double(maximumDimension), viewport.height)) / scale)
            let origin = CGPoint(
                x: max(0, min(Double(source.width) - width, center.x * Double(source.width) - width / 2)),
                y: max(0, min(Double(source.height) - height, center.y * Double(source.height) - height / 2)))
            let rect = CGRect(origin: origin, size: CGSize(width: width, height: height)).integral
            let cropped = try ImagePixels.cropped(source, to: rect)
            let previewWidth = max(1, min(maximumDimension, Int(Double(cropped.width) * min(1, scale))))
            let previewHeight = max(1, min(maximumDimension, Int(Double(cropped.height) * min(1, scale))))
            if previewWidth != cropped.width || previewHeight != cropped.height {
                image = try ImagePixels.scaled(cropped, width: previewWidth, height: previewHeight)
            } else {
                image = try ImagePixels.draw(width: previewWidth, height: previewHeight, like: cropped, fill: nil) {
                    $0.draw(cropped, in: CGRect(x: 0, y: 0, width: previewWidth, height: previewHeight))
                }
            }
            displaySize = CGSize(width: Double(cropped.width) * scale, height: Double(cropped.height) * scale)
        } else {
            let fit = min(1, Double(maximumDimension) / Double(max(source.width, source.height)))
            image = try ImagePixels.scaled(
                source, width: max(1, Int(Double(source.width) * fit)),
                height: max(1, Int(Double(source.height) * fit)))
            displaySize = nil
        }
        return ActivityImagePreview(
            image: image, width: document.first.width, height: document.first.height, displaySize: displaySize)
    }
}
