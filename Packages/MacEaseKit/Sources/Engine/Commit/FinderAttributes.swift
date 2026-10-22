import Darwin
import Foundation

struct FinderAttributes {
    private static let commentAttribute = "com.apple.metadata:kMDItemFinderComment"

    let creationDate: Date?
    let modificationDate: Date?
    let tagNames: [String]
    let comment: Data?

    init(of url: URL) throws {
        let values = try url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .tagNamesKey])
        creationDate = values.creationDate
        modificationDate = values.contentModificationDate
        tagNames = values.tagNames ?? []
        comment = try Self.extendedAttribute(Self.commentAttribute, of: url)
    }

    func apply(to url: URL) throws {
        var values = URLResourceValues()
        values.creationDate = creationDate
        values.contentModificationDate = modificationDate
        var target = url
        try target.setResourceValues(values)
        if !tagNames.isEmpty {
            try (url as NSURL).setResourceValue(tagNames, forKey: .tagNamesKey)
        }
        if let comment {
            let status = comment.withUnsafeBytes { bytes in
                setxattr(url.path, Self.commentAttribute, bytes.baseAddress, bytes.count, 0, 0)
            }
            guard status == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        }
    }

    private static func extendedAttribute(_ name: String, of url: URL) throws -> Data? {
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        if size < 0 {
            if errno == ENOATTR { return nil }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, 0) }
        guard read >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return data.prefix(read)
    }
}
