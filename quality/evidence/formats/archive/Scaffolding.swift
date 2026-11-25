import CArchive
import Glibc
import Foundation
public enum ArchiveError: Error { case duplicateRootName(String) }
enum ArchiveListing {
    static func inUTF8Locale<T>(_ body: () throws -> T) throws -> T {
        guard let locale = newlocale(Int32(LC_CTYPE_MASK), "C.UTF-8", nil) else { throw FormatError.io("UTF-8 locale") }
        let previous = uselocale(locale)
        defer { uselocale(previous); freelocale(locale) }
        return try body()
    }
    static func message(_ archive: OpaquePointer) -> String {
        archive_error_string(archive).map { String(cString: $0) } ?? "unknown libarchive error"
    }
}
extension FileHandle {
    func readChunk(upToCount count: Int) throws -> Data? { try read(upToCount: count) }
}
