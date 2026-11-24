import Compression
import CoreVideo
import Formats
import Foundation

final class ReversedFrameSpill {
    private static let pageBytes = 64 << 10
    static let maximumBufferedBytes = 256 << 20

    struct Frame {
        let timestamp: Int64
        let offset: UInt64
        let length: UInt64
        let width: Int
        let height: Int
        let format: OSType
        let planes: [(stride: Int, height: Int)]
        let attachments: CFDictionary?
    }

    private let file: FileHandle
    private(set) var frames: [Frame] = []
    private(set) var peakBufferedBytes = 0
    private(set) var bytesWritten: UInt64 = 0

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw EngineError.encodeFailed("cannot create reverse frame spill")
        }
        file = try FileHandle(forUpdating: url)
    }

    func append(_ frame: DecodedFrame) throws {
        try Task.checkCancellation()
        let image = frame.image
        let planeCount = CVPixelBufferGetPlaneCount(image)
        let planes = (0..<max(1, planeCount)).map { index in
            (
                stride: planeCount == 0
                    ? CVPixelBufferGetBytesPerRow(image) : CVPixelBufferGetBytesPerRowOfPlane(image, index),
                height: planeCount == 0 ? CVPixelBufferGetHeight(image) : CVPixelBufferGetHeightOfPlane(image, index)
            )
        }
        let bytes = planes.reduce(0) { $0 + $1.stride * $1.height }
        guard bytes <= Self.maximumBufferedBytes else { throw EngineError.invalidInput(.frameMemoryExceeded) }
        peakBufferedBytes = max(peakBufferedBytes, bytes)
        guard CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess else {
            throw EngineError.decodeFailed("cannot lock reverse frame")
        }
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let offset = try file.offset()
        let filter = try OutputFilter(.compress, using: .lz4, bufferCapacity: Self.pageBytes) { [file] bytes in
            if let bytes { try file.write(contentsOf: bytes) }
        }
        for (index, plane) in planes.enumerated() {
            guard
                let base = planeCount == 0
                    ? CVPixelBufferGetBaseAddress(image) : CVPixelBufferGetBaseAddressOfPlane(image, index)
            else {
                throw EngineError.decodeFailed("reverse frame has no pixels")
            }
            let count = plane.stride * plane.height
            for start in stride(from: 0, to: count, by: Self.pageBytes) {
                try Task.checkCancellation()
                let block = Data(
                    bytesNoCopy: base.advanced(by: start), count: min(Self.pageBytes, count - start), deallocator: .none
                )
                try filter.write(block)
            }
        }
        try filter.finalize()
        bytesWritten = try file.offset()
        frames.append(
            Frame(
                timestamp: frame.timestamp, offset: offset, length: try file.offset() - offset,
                width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image),
                format: CVPixelBufferGetPixelFormatType(image), planes: planes,
                attachments: CVBufferCopyAttachments(image, .shouldPropagate)))
    }

    func sortFrames() throws {
        frames.sort { $0.timestamp < $1.timestamp }
        guard zip(frames, frames.dropFirst()).allSatisfy({ $0.timestamp < $1.timestamp }) else {
            throw EngineError.decodeFailed("duplicate reverse frame timestamp")
        }
    }

    func image(at index: Int) throws -> CVPixelBuffer {
        try Task.checkCancellation()
        let frame = frames[index]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil, frame.width, frame.height, frame.format,
            [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferBytesPerRowAlignmentKey as String: frame.planes[0].stride,
            ] as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw EngineError.decodeFailed("cannot allocate reverse frame")
        }
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
            throw EngineError.decodeFailed("cannot lock restored reverse frame")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        try file.seek(toOffset: frame.offset)
        var remaining = frame.length
        let filter = try InputFilter<Data>(.decompress, using: .lz4, bufferCapacity: Self.pageBytes) {
            [file] requested in
            guard remaining > 0 else { return nil }
            let count = min(requested, Int(remaining))
            guard let bytes = try file.read(upToCount: count), !bytes.isEmpty else {
                throw EngineError.decodeFailed("truncated reverse frame spill")
            }
            remaining -= UInt64(bytes.count)
            return bytes
        }
        let planar = CVPixelBufferGetPlaneCount(buffer) > 0
        for (index, plane) in frame.planes.enumerated() {
            let rowBytes =
                planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, index) : CVPixelBufferGetBytesPerRow(buffer)
            guard rowBytes >= plane.stride,
                let base = planar
                    ? CVPixelBufferGetBaseAddressOfPlane(buffer, index) : CVPixelBufferGetBaseAddress(buffer)
            else { throw EngineError.decodeFailed("reverse frame layout changed") }
            for row in 0..<plane.height {
                var copied = 0
                while copied < plane.stride {
                    try Task.checkCancellation()
                    guard let bytes = try filter.readData(ofLength: min(Self.pageBytes, plane.stride - copied)),
                        !bytes.isEmpty
                    else {
                        throw EngineError.decodeFailed("truncated reverse frame pixels")
                    }
                    bytes.copyBytes(
                        to: base.advanced(by: row * rowBytes + copied).assumingMemoryBound(to: UInt8.self),
                        count: bytes.count)
                    copied += bytes.count
                }
            }
        }
        if let trailing = try filter.readData(ofLength: 1), !trailing.isEmpty {
            throw EngineError.decodeFailed("excess reverse frame pixels")
        }
        if let attachments = frame.attachments { CVBufferSetAttachments(buffer, attachments, .shouldPropagate) }
        return buffer
    }

    func close() throws {
        try file.close()
    }
}
