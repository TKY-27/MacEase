import CArchive
import Foundation

public enum ArchiveListing {
    private static let blockSize = 64 * 1024

    public static func verify(_ url: URL) throws {
        guard let archive = archive_read_new() else { throw FormatError.io("libarchive allocation") }
        defer { archive_read_free(archive) }
        archive_read_support_filter_all(archive)
        archive_read_support_format_all(archive)
        guard archive_read_open_filename(archive, url.path, blockSize) == ARCHIVE_OK else {
            throw FormatError.corrupt(message(archive))
        }
        var entry: OpaquePointer?
        var count = 0
        while true {
            let status = archive_read_next_header(archive, &entry)
            if status == ARCHIVE_EOF { break }
            guard status == ARCHIVE_OK || status == ARCHIVE_WARN else {
                throw FormatError.corrupt(message(archive))
            }
            count += 1
        }
        guard count > 0 else { throw FormatError.corrupt("archive has no entries") }
    }

    static func message(_ archive: OpaquePointer) -> String {
        archive_error_string(archive).map { String(cString: $0) } ?? "unknown libarchive error"
    }
}
