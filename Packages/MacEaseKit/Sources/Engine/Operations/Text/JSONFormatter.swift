import CJSONCompare
import Darwin
import Foundation

enum JSONFormatter {
    static func write(_ source: URL, _ formatting: JSONFormatting, settings: TextSettings, to destination: URL) throws {
        try Task.checkCancellation()
        let directory = destination.deletingLastPathComponent().appendingPathComponent(".json-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let normalized = directory.appendingPathComponent("utf8")
        _ = try StreamingText.transcode(source, to: normalized, target: .utf8, source: nil, settings: settings)
        let output = try JSONFile(destination)
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: destination) } }
        let indentation = formatting == .minify ? nil : settings.jsonIndent.unit
        if formatting == .sortKeys {
            let index = try JSONIndex(directory: directory)
            try JSONScanner(url: normalized, emit: index.accept).parse()
            try index.flush()
            let sorter = try JSONExternalSort(index: index, directory: directory, settings: settings)
            try sorter.prepare()
            try sorter.write(indent: settings.jsonIndent.unit, to: output)
            try output.append("\n")
        } else {
            let writer = JSONOutput(output: output, indentation: indentation)
            try JSONScanner(url: normalized, emit: writer.accept).parse()
            if indentation != nil { try output.append("\n") }
        }
        try output.flush()
        try output.file.close()
        try FileManager.default.removeItem(at: directory)
        finished = true
    }
}

final class JSONOutput {
    private struct Frame {
        let kind: JSONToken
        var count = 0
    }
    private let output: JSONFile
    private let indentation: String?
    private var frames: [Frame] = []
    private var scalarKind = JSONToken.null

    init(output: JSONFile, indentation: String?) {
        self.output = output
        self.indentation = indentation
    }

    func accept(_ event: JSONEvent) throws {
        switch event {
        case .begin(let kind):
            scalarKind = kind
            if kind == .key || frames.last?.kind == .array { try separator() }
            if kind == .object || kind == .array {
                try output.append(kind == .object ? "{" : "[")
                frames.append(Frame(kind: kind))
            } else if kind == .string || kind == .key {
                try output.append("\"")
            }
        case .bytes(let bytes):
            if scalarKind == .string || scalarKind == .key {
                try Self.escaped(bytes, to: output)
            } else {
                try output.append(Data(bytes))
            }
        case .end(let kind):
            if kind == .object || kind == .array {
                let frame = frames.removeLast()
                if frame.count > 0 { try line(frames.count) }
                try output.append(kind == .object ? "}" : "]")
            } else if kind == .string || kind == .key {
                try output.append("\"")
            }
            if kind == .key { try output.append(indentation == nil ? ":" : ": ") }
        }
    }

    private func separator() throws {
        let index = frames.count - 1
        if frames[index].count > 0 { try output.append(",") }
        frames[index].count += 1
        try line(frames.count)
    }

    private func line(_ level: Int) throws {
        if let indentation { try output.append("\n" + String(repeating: indentation, count: level)) }
    }

    static func escaped(_ bytes: [UInt8], to output: JSONFile) throws {
        var escaped = Data()
        escaped.reserveCapacity(JSONFile.chunkBytes)
        for byte in bytes {
            switch byte {
            case 34: escaped.append(contentsOf: [92, 34])
            case 92: escaped.append(contentsOf: [92, 92])
            case 10: escaped.append(contentsOf: [92, 110])
            case 13: escaped.append(contentsOf: [92, 114])
            case 9: escaped.append(contentsOf: [92, 116])
            case 8: escaped.append(contentsOf: [92, 98])
            case 12: escaped.append(contentsOf: [92, 102])
            case 0..<32:
                let hex = String(byte, radix: 16)
                escaped.append(contentsOf: ("\\u" + String(repeating: "0", count: 4 - hex.count) + hex).utf8)
            default: escaped.append(byte)
            }
            if escaped.count >= JSONFile.chunkBytes {
                try output.append(escaped)
                escaped.removeAll(keepingCapacity: true)
            }
        }
        if !escaped.isEmpty { try output.append(escaped) }
    }
}

private final class JSONExternalSort {
    private struct Reference {
        var index: UInt64
        var span: JSONSpan
        var folded: JSONSpan
        var natural: JSONSpan
        var rank: UInt64
        static var size: UInt64 { UInt64(MemoryLayout<Self>.size) }
    }
    private static let runCapacity = 32 * 1024
    private static let orderBytes = MemoryLayout<UInt64>.size
    private let index: JSONIndex
    private let directory: URL
    private let settings: TextSettings
    private let orders: JSONFile
    private let folded: JSONFile
    private let natural: JSONFile?
    private let comparisonDirectory: FileHandle?
    private var pinned: [JSONSpan] = []

    init(index: JSONIndex, directory: URL, settings: TextSettings) throws {
        self.index = index
        self.directory = directory
        self.settings = settings
        orders = try JSONFile(directory.appendingPathComponent("order"))
        folded = try JSONFile(directory.appendingPathComponent("folded"))
        if settings.jsonKeyComparison == .natural {
            natural = try JSONFile(directory.appendingPathComponent("natural"))
            let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            comparisonDirectory = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        } else {
            natural = nil
            comparisonDirectory = nil
        }
        for key in settings.jsonPinnedKeys {
            let start = index.keys.count
            var chunk = Data()
            for byte in key.utf8 {
                chunk.append(byte)
                if chunk.count == JSONFile.chunkBytes {
                    try index.keys.append(chunk)
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            if !chunk.isEmpty { try index.keys.append(chunk) }
            pinned.append(
                try folded.appendCaseFolded(JSONSpan(offset: start, length: index.keys.count - start), from: index.keys)
            )
        }
    }

    func prepare() throws {
        var position: UInt64 = 0
        while position < index.count {
            try Task.checkCancellation()
            var record = try index.record(position)
            let object = record.kind == JSONToken.object.rawValue
            let sortable =
                object
                || (record.kind == JSONToken.array.rawValue && record.primitiveChildren == 1
                    && settings.jsonSortPrimitiveArrays)
            if sortable, record.children > 1 {
                record.order = orders.count + 1
                try sort(record, at: position, object: object)
                try index.records.replace(record, at: position * JSONRecord.size)
            }
            if settings.keySortScope != .recursive { break }
            position += 1
        }
        try orders.flush()
        try index.records.flush()
    }

    private func sort(_ record: JSONRecord, at position: UInt64, object: Bool) throws {
        var references: [Reference] = []
        references.reserveCapacity(Self.runCapacity)
        var child = position + 1
        var run: JSONFile?
        let firstURL = directory.appendingPathComponent("runs-a")
        let secondURL = directory.appendingPathComponent("runs-b")
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        for ordinal in 0..<record.children {
            let member = try index.record(child)
            var foldedKey = JSONSpan()
            var naturalKey = JSONSpan()
            var rank = pinned.count
            if object, settings.jsonKeyComparison != .ordinal || !pinned.isEmpty {
                naturalKey.offset = natural?.count ?? 0
                foldedKey = try folded.appendCaseFolded(member.rawKey, from: index.keys, utf16: natural)
                naturalKey.length = (natural?.count ?? 0) - naturalKey.offset
                for (offset, pin) in pinned.enumerated() {
                    if try folded.compare(foldedKey, pin) == .orderedSame {
                        rank = offset
                        break
                    }
                }
            }
            references.append(
                Reference(
                    index: child, span: object ? member.rawKey : member.payload, folded: foldedKey, natural: naturalKey,
                    rank: UInt64(rank)))
            child = member.end
            if references.count == Self.runCapacity || ordinal + 1 == record.children {
                try references.sort { try precedes($0, $1, object: object) }
                if record.children <= UInt64(Self.runCapacity) {
                    for reference in references { try appendOrder(reference.index) }
                } else {
                    if run == nil { run = try JSONFile(firstURL) }
                    if let run {
                        for reference in references {
                            try run.append(withUnsafeBytes(of: reference) { Data($0) })
                        }
                    }
                }
                references.removeAll(keepingCapacity: true)
            }
        }
        guard let run else { return }
        try run.flush()
        try run.file.close()
        var source = firstURL
        var target = secondURL
        var width = UInt64(Self.runCapacity)
        while width < record.children {
            let left = try JSONFile(reading: source)
            let right = try JSONFile(reading: source)
            let merged = try JSONFile(target)
            var start: UInt64 = 0
            while start < record.children {
                let middle = min(start + width, record.children)
                let end = min(middle + width, record.children)
                var leftPosition = start
                var rightPosition = middle
                var leftReference = leftPosition < middle ? try reference(left, at: leftPosition) : nil
                var rightReference = rightPosition < end ? try reference(right, at: rightPosition) : nil
                while leftReference != nil || rightReference != nil {
                    try Task.checkCancellation()
                    let next: Reference
                    if let candidate = leftReference,
                        try rightReference.map({ try precedes(candidate, $0, object: object) }) ?? true
                    {
                        next = candidate
                        leftPosition += 1
                        leftReference = leftPosition < middle ? try reference(left, at: leftPosition) : nil
                    } else if let candidate = rightReference {
                        next = candidate
                        rightPosition += 1
                        rightReference = rightPosition < end ? try reference(right, at: rightPosition) : nil
                    } else {
                        break
                    }
                    try merged.append(withUnsafeBytes(of: next) { Data($0) })
                }
                start = end
            }
            try merged.flush()
            try merged.file.close()
            try left.file.close()
            try right.file.close()
            try FileManager.default.removeItem(at: source)
            swap(&source, &target)
            width = min(record.children, width * 2)
        }
        let sorted = try JSONFile(reading: source)
        for ordinal in 0..<record.children { try appendOrder(reference(sorted, at: ordinal).index) }
        try sorted.file.close()
    }

    private func appendOrder(_ position: UInt64) throws {
        try orders.append(withUnsafeBytes(of: position) { Data($0) })
    }

    private func reference(_ file: JSONFile, at position: UInt64) throws -> Reference {
        try file.read(at: position * Reference.size, count: Int(Reference.size)).withUnsafeBytes {
            $0.loadUnaligned(as: Reference.self)
        }
    }

    private func precedes(_ left: Reference, _ right: Reference, object: Bool) throws -> Bool {
        try Task.checkCancellation()
        if left.rank != right.rank { return left.rank < right.rank }
        let spool = object ? index.keys : index.payload
        let ordinal = try spool.compare(left.span, right.span)
        var order = ordinal
        if object, settings.jsonKeyComparison != .ordinal, ordinal != .orderedSame {
            var primary = try folded.compare(left.folded, right.folded)
            if settings.jsonKeyComparison == .natural, primary != .orderedSame {
                primary = try naturalOrder(left.natural, right.natural)
            }
            if primary != .orderedSame { order = primary }
        }
        if order == .orderedSame { return left.index < right.index }
        return settings.jsonDescending ? order == .orderedDescending : order == .orderedAscending
    }

    private func naturalOrder(_ left: JSONSpan, _ right: JSONSpan) throws -> ComparisonResult {
        guard let natural, let comparisonDirectory else {
            throw EngineError.unexpected("Missing JSON natural comparison storage")
        }
        try natural.flush()
        let result = MEJSONCompareFoldedUTF16(
            MEJSONUTF16Span(descriptor: natural.file.fileDescriptor, byteOffset: left.offset, byteLength: left.length),
            MEJSONUTF16Span(
                descriptor: natural.file.fileDescriptor, byteOffset: right.offset, byteLength: right.length),
            comparisonDirectory.fileDescriptor, { _ in Task<Never, Never>.isCancelled ? 1 : 0 }, nil)
        switch result.status {
        case ME_JSON_COMPARE_OK:
            if result.ordering == 0 { return .orderedSame }
            return result.ordering < 0 ? .orderedAscending : .orderedDescending
        case ME_JSON_COMPARE_CANCELLED:
            throw CancellationError()
        case ME_JSON_COMPARE_IO:
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(result.systemError))
        case ME_JSON_COMPARE_OFFSET_OVERFLOW:
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EFBIG))
        case ME_JSON_COMPARE_MEMORY:
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOMEM))
        default:
            throw EngineError.unexpected(
                "JSON collation failed (status \(result.status.rawValue), ICU \(result.icuError))")
        }
    }

    private struct WriteFrame {
        let record: JSONRecord
        var nextChild: UInt64
        var ordinal: UInt64 = 0
        var object: Bool { record.kind == JSONToken.object.rawValue }
    }

    func write(indent: String, to output: JSONFile) throws {
        var frames: [WriteFrame] = []
        var next: UInt64? = 0
        while next != nil || !frames.isEmpty {
            try Task.checkCancellation()
            if let position = next {
                let record = try index.record(position)
                let object = record.kind == JSONToken.object.rawValue
                if object || record.kind == JSONToken.array.rawValue {
                    try output.append(object ? "{" : "[")
                    if record.children == 0 {
                        try output.append(object ? "}" : "]")
                    } else {
                        frames.append(WriteFrame(record: record, nextChild: position + 1))
                    }
                } else {
                    try index.payload.copy(record.payload, to: output)
                }
                next = nil
                continue
            }
            let frameIndex = frames.count - 1
            let frame = frames[frameIndex]
            if frame.ordinal == frame.record.children {
                try output.append("\n" + String(repeating: indent, count: frameIndex))
                try output.append(frame.object ? "}" : "]")
                frames.removeLast()
                continue
            }
            if frame.ordinal > 0 { try output.append(",") }
            try output.append("\n" + String(repeating: indent, count: frames.count))
            var child = frame.nextChild
            if frame.record.order > 0 {
                child = try orders.read(
                    at: frame.record.order - 1 + frame.ordinal * UInt64(Self.orderBytes), count: Self.orderBytes
                ).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
            }
            let member = try index.record(child)
            if frame.object {
                try index.payload.copy(member.key, to: output)
                try output.append(": ")
            }
            frames[frameIndex].nextChild = member.end
            frames[frameIndex].ordinal += 1
            next = child
        }
    }
}
