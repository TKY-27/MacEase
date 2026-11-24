import CArchive

public enum ArchiveReadSupport {
    public static func enableFilters(_ archive: OpaquePointer, compressed: Bool = true) throws {
        let registrations =
            compressed
            ? [
                archive_read_support_filter_gzip, archive_read_support_filter_bzip2,
                archive_read_support_filter_xz, archive_read_support_filter_zstd,
            ] : [archive_read_support_filter_none]
        // ARCHIVE_WARN permits an external decompressor.
        for register in registrations {
            guard register(archive) == ARCHIVE_OK else {
                throw FormatError.unsupported(ArchiveListing.message(archive))
            }
        }
    }

    static func enableFormats(_ archive: OpaquePointer) throws {
        let registrations = [
            archive_read_support_format_zip, archive_read_support_format_tar,
            archive_read_support_format_7zip, archive_read_support_format_rar, archive_read_support_format_rar5,
        ]
        for register in registrations {
            guard register(archive) == ARCHIVE_OK else {
                throw FormatError.unsupported(ArchiveListing.message(archive))
            }
        }
    }

    static func checkRawPrefix(_ bytes: UnsafeRawBufferPointer) throws {
        let signatures: [[UInt8]] = [
            [0x04, 0x22, 0x4D, 0x18], [0x02, 0x21, 0x4C, 0x18],
            [0x89, 0x4C, 0x5A, 0x4F, 0x00, 0x0D, 0x0A, 0x1A, 0x0A],
            [0x4C, 0x52, 0x5A, 0x49],
            [0x47, 0x52, 0x5A, 0x69, 0x70, 0x49, 0x49, 0x00, 0x02, 0x04, 0x3A, 0x29],
        ]
        guard !signatures.contains(where: { bytes.starts(with: $0) }) else {
            throw FormatError.corrupt("unsupported archive compression")
        }
    }
}
