import CJSONCompare
import Darwin
import Foundation
import Testing

@testable import Engine

@Suite struct JSONNaturalComparisonTests {
    private struct CancellationObservation {
        var polls = 0
        var sawSpilledFile = false
        let directory: Int32
    }

    private static func unlinkedScratchDescriptors(in directory: Int32) -> [Int32] {
        var path = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let directoryResult = fcntl(directory, F_GETPATH, &path)
        #expect(directoryResult == 0)
        guard directoryResult == 0 else { return [] }
        let prefix = String(decoding: path.prefix { $0 != 0 }, as: UTF8.self) + "/"
        return (0..<getdtablesize()).filter { descriptor in
            let result = fcntl(descriptor, F_GETPATH, &path)
            guard result == 0, String(decoding: path.prefix { $0 != 0 }, as: UTF8.self).hasPrefix(prefix) else {
                return false
            }
            var details = stat()
            return fstat(descriptor, &details) == 0 && details.st_nlink == 0
        }
    }

    private func fixture(
        _ body: (MEJSONUTF16Span, MEJSONUTF16Span, FileHandle, URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        let left = try JSONFile(directory.appending(path: "left"))
        let right = try JSONFile(directory.appending(path: "right"))
        for (file, mark) in [(left, UInt16(0x301)), (right, UInt16(0x300))] {
            let prefix: [UInt16] = [0x61, mark]
            try prefix.withUnsafeBytes { try file.append(Data($0)) }
            let chunk = Array(repeating: UInt16(0x78), count: 32_768)
            for _ in 0..<32 { try chunk.withUnsafeBytes { try file.append(Data($0)) } }
            try file.flush()
        }
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let scratch = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try body(
            MEJSONUTF16Span(descriptor: left.file.fileDescriptor, byteOffset: 0, byteLength: left.count),
            MEJSONUTF16Span(descriptor: right.file.fileDescriptor, byteOffset: 0, byteLength: right.count),
            scratch, directory)
        #expect(fcntl(left.file.fileDescriptor, F_GETFD) >= 0)
        #expect(fcntl(right.file.fileDescriptor, F_GETFD) >= 0)
        #expect(Self.unlinkedScratchDescriptors(in: scratch.fileDescriptor).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["left", "right"])
    }

    @Test func nativeComparisonRetainsSecondaryOrderAcrossFilePages() throws {
        try fixture { left, right, scratch, _ in
            let result = MEJSONCompareFoldedUTF16(left, right, scratch.fileDescriptor, nil, nil)
            #expect(result.status == ME_JSON_COMPARE_OK)
            #expect(result.ordering == -1)
        }
    }

    @Test func nativeCancellationClosesSpilledComparisonFiles() throws {
        try fixture { left, right, scratch, _ in
            var observation = CancellationObservation(directory: scratch.fileDescriptor)
            let result = withUnsafeMutablePointer(to: &observation) { context in
                MEJSONCompareFoldedUTF16(
                    left, right, scratch.fileDescriptor,
                    { context in
                        guard let context else { return 0 }
                        let observation = context.assumingMemoryBound(to: CancellationObservation.self)
                        observation.pointee.polls += 1
                        observation.pointee.sawSpilledFile =
                            !Self.unlinkedScratchDescriptors(in: observation.pointee.directory).isEmpty
                        return observation.pointee.sawSpilledFile ? 1 : 0
                    }, context)
            }
            #expect(observation.polls > 0)
            #expect(observation.sawSpilledFile)
            #expect(result.status == ME_JSON_COMPARE_CANCELLED)
        }
    }

    @Test func nativeComparisonRejectsInvalidSpansWithoutClaimingAnOrder() throws {
        try fixture { left, right, scratch, _ in
            var invalid = left
            invalid.byteLength += 1
            let odd = MEJSONCompareFoldedUTF16(invalid, right, scratch.fileDescriptor, nil, nil)
            #expect(odd.status == ME_JSON_COMPARE_INVALID_SPAN)
            invalid = left
            invalid.byteOffset = UInt64(Int64.max)
            let overflow = MEJSONCompareFoldedUTF16(invalid, right, scratch.fileDescriptor, nil, nil)
            #expect(overflow.status == ME_JSON_COMPARE_OFFSET_OVERFLOW)
            invalid = left
            invalid.descriptor = -1
            let missing = MEJSONCompareFoldedUTF16(invalid, right, scratch.fileDescriptor, nil, nil)
            #expect(missing.status == ME_JSON_COMPARE_IO)
            #expect(missing.systemError == EBADF)
        }
    }
}
