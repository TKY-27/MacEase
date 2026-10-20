import CArchive
import Darwin
import Foundation

public enum ArchiveWriter {
    private static let chunkSize = 1 << 20

    private struct Member {
        let path: String
        let name: String
        let status: stat

        var isDirectory: Bool { status.st_mode & S_IFMT == S_IFDIR }
        var isRegularFile: Bool { status.st_mode & S_IFMT == S_IFREG }
    }

    /// Symlinks are stored as links, never followed.
    public static func write(
        _ roots: [URL],
        to destination: URL,
        format: ArchiveFormat,
        progress: (Double) -> Void,
        skipping isSkipped: (String) -> Bool
    ) throws {
        var members: [Member] = []
        for root in roots {
            try collect(root.path, as: root.lastPathComponent, skipping: isSkipped, into: &members)
        }
        let total = max(1, members.reduce(Int64(0)) { $0 + ($1.isRegularFile ? Int64($1.status.st_size) : 0) })
        try ArchiveListing.inUTF8Locale {
            guard let archive = archive_write_new() else { throw FormatError.io("libarchive allocation") }
            defer { archive_write_free(archive) }
            try configure(archive, for: format)
            try check(archive_write_open_filename(archive, destination.path), archive)
            var written: Int64 = 0
            for member in members {
                try Task.checkCancellation()
                try add(member, to: archive) { bytes in
                    written += Int64(bytes)
                    progress(Double(written) / Double(total))
                }
            }
            try check(archive_write_close(archive), archive)
        }
    }

    private static func configure(_ archive: OpaquePointer, for format: ArchiveFormat) throws {
        switch format {
        case .zip:
            try check(archive_write_set_format_zip(archive), archive)
            try check(archive_write_set_format_option(archive, "zip", "hdrcharset", "UTF-8"), archive)
        case .sevenZip:
            try check(archive_write_set_format_7zip(archive), archive)
        case .tar:
            try check(archive_write_set_format_pax_restricted(archive), archive)
        case .tarGzip:
            try check(archive_write_set_format_pax_restricted(archive), archive)
            try check(archive_write_add_filter_gzip(archive), archive)
        }
    }

    private static func collect(
        _ path: String,
        as name: String,
        skipping isSkipped: (String) -> Bool,
        into members: inout [Member]
    ) throws {
        var status = stat()
        guard lstat(path, &status) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let member = Member(path: path, name: name, status: status)
        members.append(member)
        guard member.isDirectory else { return }
        let children = try FileManager.default.contentsOfDirectory(atPath: path).sorted()
        for child in children where !isSkipped(child) {
            try collect(path + "/" + child, as: name + "/" + child, skipping: isSkipped, into: &members)
        }
    }

    private static func add(_ member: Member, to archive: OpaquePointer, wrote: (Int) -> Void) throws {
        guard let entry = archive_entry_new() else { throw FormatError.io("libarchive allocation") }
        defer { archive_entry_free(entry) }
        var status = member.status
        archive_entry_copy_stat(entry, &status)
        archive_entry_set_pathname_utf8(entry, member.name)
        if member.status.st_mode & S_IFMT == S_IFLNK {
            archive_entry_set_symlink_utf8(
                entry, try FileManager.default.destinationOfSymbolicLink(atPath: member.path))
        }
        try check(archive_write_header(archive, entry), archive)
        guard member.isRegularFile else { return }
        let reader = try FileHandle(forReadingFrom: URL(fileURLWithPath: member.path))
        defer { try? reader.close() }
        while let chunk = try reader.read(upToCount: chunkSize), !chunk.isEmpty {
            try Task.checkCancellation()
            let count = chunk.withUnsafeBytes { archive_write_data(archive, $0.baseAddress, $0.count) }
            guard count == chunk.count else { throw FormatError.encoderFailure(ArchiveListing.message(archive)) }
            wrote(count)
        }
    }

    private static func check(_ status: Int32, _ archive: OpaquePointer) throws {
        guard status == ARCHIVE_OK else { throw FormatError.encoderFailure(ArchiveListing.message(archive)) }
    }
}
