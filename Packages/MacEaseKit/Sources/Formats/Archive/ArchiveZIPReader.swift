import CArchive
import Foundation

final class ArchiveZIPReader {
    let archive: OpaquePointer
    let directory: ZIPDirectory
    let encoding: ArchivePathname.LegacyEncoding
    let source: ArchiveReadSource
    private var ordinal = 0

    init(
        source: ArchiveReadSource, directory supplied: ZIPDirectory? = nil,
        password: String? = nil, prefersJapanese: Bool, inspectLinks: Bool = true,
        bounded: Bool = true, check: () throws -> Void = {}
    ) throws {
        let directory = try supplied ?? ZIPDirectoryBounds.validate(source: source, bounded: bounded, check: check)
        var encoding: ArchivePathname.LegacyEncoding = .cp437
        if prefersJapanese {
            do {
                for member in directory.members { _ = try ArchivePathname.decode(member.name, encoding: .cp932) }
                encoding = .cp932
            } catch ArchiveError.unsupportedNameEncoding { encoding = .cp437 }
        }
        var pointer = try Self.open(source, directory: directory, password: password)
        do {
            if inspectLinks, encoding == .cp932,
                directory.members.contains(where: \.isSymlink),
                !directory.members.contains(where: {
                    $0.isSymlink && ($0.flags & 1 != 0 || ![0, 8, 14].contains($0.method))
                })
            {
                var entry: OpaquePointer?
                while true {
                    try check()
                    let status = archive_read_next_header(pointer, &entry)
                    if let failure = source.failure { throw failure }
                    if status == ARCHIVE_EOF { break }
                    guard status >= ARCHIVE_WARN, let entry else {
                        throw FormatError.corrupt(ArchiveListing.message(pointer))
                    }
                    do {
                        _ = try ArchivePathname.symlink(entry, encoding: .cp932)
                        _ = try ArchivePathname.hardlink(entry, encoding: .cp932)
                    } catch ArchiveError.unsupportedNameEncoding { encoding = .cp437 }
                }
                let reopened = try Self.open(source, directory: directory, password: password)
                archive_read_free(pointer)
                pointer = reopened
            }
        } catch {
            archive_read_free(pointer)
            throw error
        }
        self.archive = pointer
        self.source = source
        self.directory = directory
        self.encoding = encoding
    }

    deinit { _ = withExtendedLifetime(source) { archive_read_free(archive) } }

    func next() throws -> OpaquePointer? {
        var entry: OpaquePointer?
        let status = archive_read_next_header(archive, &entry)
        if let failure = source.failure { throw failure }
        if status == ARCHIVE_EOF {
            guard ordinal == directory.members.count else { throw ZIPBrowserError.invalidZIP }
            return nil
        }
        guard status >= ARCHIVE_WARN, let entry, ordinal < directory.members.count else {
            throw FormatError.corrupt(ArchiveListing.message(archive))
        }
        let member = directory.members[ordinal]
        let pathname = try ArchivePathname.decode(member.name, encoding: encoding)
        archive_entry_set_pathname_utf8(entry, pathname)
        ordinal += 1
        return entry
    }

    static func archiveError(_ error: any Error) -> any Error {
        if case ZIPBrowserError.unsafeEntry = error { return ArchiveError.unsafePath("ZIP filename contains NUL") }
        if error is ZIPBrowserError { return FormatError.corrupt("invalid ZIP directory") }
        return error
    }

    static func recognizes(_ source: ArchiveReadSource, check: () throws -> Void = {}) throws -> Bool {
        let count = Int(min(source.size, Int64(22 + Int(UInt16.max))))
        guard count >= 4 else { return false }
        let prefix = try source.read(at: 0, count: 4, check: check)
        if prefix == [0x50, 0x4B, 0x03, 0x04] || prefix == [0x50, 0x4B, 0x05, 0x06] { return true }
        guard count >= 22 else { return false }
        let tail = try source.read(at: source.size - Int64(count), count: count, check: check)
        return stride(from: count - 22, through: 0, by: -1).contains {
            UInt32(littleEndian: tail, at: $0) == 0x06054b50
                && $0 + 22 + Int(UInt16(littleEndian: tail, at: $0 + 20)) == tail.count
        }
    }

    private static func open(_ source: ArchiveReadSource, directory: ZIPDirectory, password: String?) throws
        -> OpaquePointer
    {
        guard let archive = archive_read_new() else { throw FormatError.io("ZIP reader allocation") }
        do {
            try ArchiveReadSupport.enableFilters(archive, compressed: false)
            guard archive_read_support_format_zip_seekable(archive) == ARCHIVE_OK,
                archive_read_set_option(archive, "zip", "mac-ext", nil) == ARCHIVE_OK
            else { throw FormatError.unsupported("seekable ZIP") }
            if let password { archive_read_add_passphrase(archive, password) }
            try source.open(archive, endingAt: directory.endOffset + 22)
            return archive
        } catch {
            archive_read_free(archive)
            throw error
        }
    }
}
