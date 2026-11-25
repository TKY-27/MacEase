import CArchive
import Foundation
import Testing
func extractForTest(_ source: URL, into root: URL) throws {
    let reader = try #require(archive_read_new())
    defer { archive_read_free(reader) }
    try #require(archive_read_support_filter_all(reader) == ARCHIVE_OK)
    try #require(archive_read_support_format_all(reader) == ARCHIVE_OK)
    try #require(archive_read_open_filename(reader, source.path, 65536) == ARCHIVE_OK)
    var entry: OpaquePointer?
    while true {
        let status = archive_read_next_header(reader, &entry)
        if status == ARCHIVE_EOF { break }
        try #require(status == ARCHIVE_OK)
        let member = try #require(entry)
        let name = String(cString: try #require(archive_entry_pathname(member)))
        archive_entry_set_pathname(member, root.appending(path: name).path)
        try #require(archive_read_extract(reader, member, 0) == ARCHIVE_OK)
    }
}
