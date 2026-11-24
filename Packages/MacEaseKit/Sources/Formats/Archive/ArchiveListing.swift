import CArchive
import Foundation

public enum ArchiveListing {

    public static func verify(
        _ url: URL, prefersJapanese: Bool = ArchivePathname.prefersJapanese(in: Locale.preferredLanguages)
    ) throws {
        _ = try verifiedEncoding(url, prefersJapanese: prefersJapanese)
    }

    static func verifiedEncoding(_ url: URL, prefersJapanese: Bool) throws -> ArchivePathname.LegacyEncoding {
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        return try inUTF8Locale {
            let source = try ArchiveReadSource([url])
            if try ArchiveZIPReader.recognizes(source) {
                let reader: ArchiveZIPReader
                do {
                    reader = try ArchiveZIPReader(source: source, prefersJapanese: prefersJapanese, bounded: false)
                } catch { throw ArchiveZIPReader.archiveError(error) }
                var count = 0
                while try reader.next() != nil { try Task.checkCancellation(); count += 1 }
                guard count > 0 else { throw FormatError.corrupt("archive has no entries") }
                return reader.encoding
            }
            guard let archive = archive_read_new() else { throw FormatError.io("libarchive allocation") }
            defer { _ = withExtendedLifetime(source) { archive_read_free(archive) } }
            try ArchiveReadSupport.enableFilters(archive)
            try ArchiveReadSupport.enableFormats(archive)
            try source.open(archive)
            var entry: OpaquePointer?
            var count = 0
            let encoding: ArchivePathname.LegacyEncoding = prefersJapanese ? .cp932 : .utf8Only
            while true {
                try Task.checkCancellation()
                let status = archive_read_next_header(archive, &entry)
                if let failure = source.failure { throw failure }
                if status == ARCHIVE_EOF { break }
                guard status >= ARCHIVE_WARN, let entry else { throw FormatError.corrupt(message(archive)) }
                if archive_format(archive) & ARCHIVE_FORMAT_BASE_MASK == ARCHIVE_FORMAT_ZIP {
                    throw ArchiveError.wrappedZIPContainer
                }
                _ = try ArchivePathname.decode(entry, encoding: encoding)
                count += 1
            }
            guard count > 0 else { throw FormatError.corrupt("archive has no entries") }
            return encoding
        }
    }

    static func message(_ archive: OpaquePointer) -> String {
        archive_error_string(archive).map { String(cString: $0) } ?? "unknown libarchive error"
    }

    /// libarchive converts names through the thread's locale.
    static func inUTF8Locale<T>(_ body: () throws -> T) throws -> T {
        guard let utf8 = newlocale(LC_CTYPE_MASK, "UTF-8", nil) else { throw FormatError.io("UTF-8 locale") }
        let previous = uselocale(utf8)
        defer {
            uselocale(previous)
            freelocale(utf8)
        }
        return try body()
    }
}
