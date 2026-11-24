import Darwin
import Foundation

struct MoveMetadata {
    static func preserve(source: URL, copy: URL) throws {
        var original = stat()
        var copied = stat()
        guard lstat(source.path, &original) == 0, lstat(copy.path, &copied) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if original.st_mode & S_IFMT == S_IFDIR {
            for name in try FileManager.default.contentsOfDirectory(atPath: source.path) {
                try Task.checkCancellation()
                try preserve(source: source.appending(path: name), copy: copy.appending(path: name))
            }
        }
        let unlocked = copied.st_flags & ~UInt32(UF_IMMUTABLE)
        if unlocked != copied.st_flags, lchflags(copy.path, unlocked) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            let expectedAttributes = try extendedAttributes(source)
            let copiedAttributes = try extendedAttributes(copy)
            for (name, contents) in expectedAttributes where copiedAttributes[name] != contents {
                let status = contents.withUnsafeBytes {
                    setxattr(copy.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
                }
                guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
            var requested = attrlist()
            requested.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
            requested.commonattr = attrgroup_t(ATTR_CMN_CRTIME | ATTR_CMN_MODTIME)
            var dates = [original.st_birthtimespec, original.st_mtimespec]
            let status = dates.withUnsafeMutableBytes {
                setattrlist(copy.path, &requested, $0.baseAddress, $0.count, UInt32(FSOPT_NOFOLLOW))
            }
            guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            if unlocked != copied.st_flags, lchflags(copy.path, copied.st_flags) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            throw error
        }
        if unlocked != copied.st_flags, lchflags(copy.path, copied.st_flags) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func verify(source: URL, copy: URL, sourceStat: stat, copyStat: stat) throws {
        let properties = [
            ("permissions", sourceStat.st_mode == copyStat.st_mode),
            ("ownership", sourceStat.st_uid == copyStat.st_uid && sourceStat.st_gid == copyStat.st_gid),
            ("BSD flags", sourceStat.st_flags == copyStat.st_flags),
            (
                "creation date",
                sourceStat.st_birthtimespec.tv_sec == copyStat.st_birthtimespec.tv_sec
                    && sourceStat.st_birthtimespec.tv_nsec == copyStat.st_birthtimespec.tv_nsec
            ),
            (
                "modification date",
                sourceStat.st_mtimespec.tv_sec == copyStat.st_mtimespec.tv_sec
                    && sourceStat.st_mtimespec.tv_nsec == copyStat.st_mtimespec.tv_nsec
            ),
            ("extended attributes", try extendedAttributes(source) == extendedAttributes(copy)),
            ("access control list", try accessControl(source) == accessControl(copy)),
        ]
        if let missing = properties.first(where: { !$0.1 }) {
            throw EngineError.commitFailed("Destination cannot preserve \(missing.0); original retained")
        }
    }

    private static func extendedAttributes(_ url: URL) throws -> [String: Data] {
        let count = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if count == 0 { return [:] }
        var names = [CChar](repeating: 0, count: count)
        let read = listxattr(url.path, &names, names.count, XATTR_NOFOLLOW)
        guard read >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var attributes: [String: Data] = [:]
        for bytes in names.prefix(read).split(separator: 0) {
            let name = String(decoding: bytes.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard size >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var contents = Data(count: size)
            let length = contents.withUnsafeMutableBytes {
                getxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
            }
            guard length == size else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            attributes[name] = contents
        }
        return attributes
    }

    private static func accessControl(_ url: URL) throws -> String {
        guard let acl = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT {
                var existing = stat()
                guard lstat(url.path, &existing) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                return ""
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let text = acl_to_text(acl, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { acl_free(text) }
        return String(cString: text)
    }
}
