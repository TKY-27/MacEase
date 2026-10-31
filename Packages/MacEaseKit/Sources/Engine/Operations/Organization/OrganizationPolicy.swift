import Darwin
import Foundation
import MenuCatalog

public struct OrganizationPolicy: Codable, Equatable, Sendable {
    public var categories: [String]
    public var instructions: String
    public var allowNewSubcategories: Bool
    public var renameOpaqueFiles: Bool
    public var stabilityDelay: TimeInterval

    public init(
        categories: [String] = [
            "Documents/Receipts", "Documents/Work", "Documents/Personal", "Images", "Video", "Audio",
        ],
        instructions: String = "", allowNewSubcategories: Bool = true, renameOpaqueFiles: Bool = true,
        stabilityDelay: TimeInterval = 120
    ) {
        self.categories = categories
        self.instructions = instructions
        self.allowNewSubcategories = allowNewSubcategories
        self.renameOpaqueFiles = renameOpaqueFiles
        self.stabilityDelay = stabilityDelay
    }

    private enum CodingKeys: String, CodingKey {
        case categories, instructions, allowNewSubcategories, renameOpaqueFiles, stabilityDelay
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        categories = try values.decode([String].self, forKey: .categories)
        instructions = try values.decode(String.self, forKey: .instructions)
        allowNewSubcategories = try values.decodeIfPresent(Bool.self, forKey: .allowNewSubcategories) ?? false
        renameOpaqueFiles = try values.decode(Bool.self, forKey: .renameOpaqueFiles)
        stabilityDelay = try values.decode(TimeInterval.self, forKey: .stabilityDelay)
    }

    public func validate() throws {
        guard !categories.isEmpty, categories.count <= 64, Set(categories).count == categories.count,
            categories.allSatisfy(Self.isCategory), instructions.count <= 2_000,
            stabilityDelay.isFinite, stabilityDelay >= 1, stabilityDelay <= 86_400
        else { throw EngineError.invalidInput(.malformed("Invalid organization policy")) }
    }

    public func acceptsCategory(_ path: String) -> Bool {
        Self.isCategory(path)
            && categories.contains { path == $0 || (allowNewSubcategories && path.hasPrefix($0 + "/")) }
    }

    public static func isCategory(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.count <= 4 && path.utf8.count <= 240
            && components.allSatisfy { AvailableName.checkedName(String($0)) && !$0.hasPrefix(".") }
    }
}

public struct OrganizationIdentity: Codable, Hashable, Sendable {
    let device: UInt64
    let inode: UInt64

    public init(of url: URL, directory: Bool) throws {
        let status = try OrganizationSafety.metadata(url)
        guard status.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else {
            throw EngineError.invalidInput(.unsupportedFileType)
        }
        device = UInt64(UInt32(bitPattern: status.st_dev))
        inode = status.st_ino
    }

    public func matches(_ url: URL, directory: Bool) -> Bool {
        (try? OrganizationIdentity(of: url, directory: directory)) == self
    }
}

public struct OrganizationMovePlan: Codable, Hashable, Sendable {
    public let root: URL
    public let rootIdentity: OrganizationIdentity
    public let source: URL
    public let sourceStamp: FileStamp
    public let category: String
    public let destinationIdentities: [String: OrganizationIdentity]
    public let proposedName: String
    public let isCorrection: Bool

    public init(root: URL, source: URL, category: String, proposedName: String? = nil, isCorrection: Bool = false)
        throws
    {
        self.root = try OrganizationSafety.normalizedRoot(root)
        _ = try OrganizationIdentity(of: source, directory: false)
        self.source = try OrganizationSafety.canonicalURL(source)
        rootIdentity = try OrganizationIdentity(of: self.root, directory: true)
        sourceStamp = try FileStamp(of: self.source, includingIdentity: true)
        self.category = category
        self.proposedName = proposedName ?? source.lastPathComponent
        self.isCorrection = isCorrection
        destinationIdentities = try OrganizationSafety.destinationIdentities(root: self.root, category: category)
        try OrganizationSafety.validate(self)
    }
}

public struct OrganizationMoveRecord: Codable, Equatable, Sendable {
    public let root: URL
    public let rootIdentity: OrganizationIdentity
    public let from: URL
    public let to: URL
    public let stamp: FileStamp
    public let category: String
}

public struct OrganizationFolderRecord: Codable, Equatable, Sendable {
    public let root: URL
    public let rootIdentity: OrganizationIdentity
    public let url: URL
    public let identity: OrganizationIdentity
}

struct OrganizationMoveIntent: Codable, Equatable, Sendable {
    let id: UUID
    let batchID: UUID
    let operation: OperationID
    let date: Date
    let move: OrganizationMoveRecord
}

public enum OrganizationSafety {
    static func metadata(_ url: URL) throws -> stat {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return status
    }

    static func canonicalURL(_ url: URL) throws -> URL {
        guard url.isFileURL, let canonical = realpath(url.path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }
        defer { free(canonical) }
        return URL(
            fileURLWithPath: FileManager.default.string(
                withFileSystemRepresentation: canonical, length: strlen(canonical)))
    }

    public static func normalizedRoot(_ url: URL) throws -> URL {
        _ = try OrganizationIdentity(of: url, directory: true)
        let root = try canonicalURL(url)
        try validateRoot(root)
        return root
    }

    public static func validateRoot(_ root: URL) throws {
        guard root.isFileURL, root.path != "/", try canonicalURL(root).path == root.path
        else { throw EngineError.invalidInput(.malformed("Organization roots cannot contain symbolic links")) }
        _ = try OrganizationIdentity(of: root, directory: true)
        guard try root.resourceValues(forKeys: [.isPackageKey]).isPackage != true else {
            throw EngineError.invalidInput(.unsupportedFileType)
        }
    }

    static func destinationIdentities(root: URL, category: String) throws -> [String: OrganizationIdentity] {
        guard OrganizationPolicy.isCategory(category) else {
            throw EngineError.invalidInput(.malformed("Invalid organization category"))
        }
        var identities: [String: OrganizationIdentity] = [:]
        var directory = root
        for component in category.split(separator: "/") {
            directory.append(path: String(component), directoryHint: .isDirectory)
            var status = stat()
            if lstat(directory.path, &status) != 0 {
                if errno == ENOENT { break }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            identities[directory.path] = try OrganizationIdentity(of: directory, directory: true)
        }
        return identities
    }

    static func validate(_ plan: OrganizationMovePlan) throws {
        try validateRoot(plan.root)
        guard plan.rootIdentity.matches(plan.root, directory: true), OrganizationPolicy.isCategory(plan.category),
            AvailableName.checkedName(plan.proposedName), !plan.proposedName.hasPrefix("."),
            plan.proposedName.utf8.count <= 255,
            contains(plan.source, in: plan.root),
            try canonicalURL(plan.source).path == plan.source.path,
            plan.isCorrection || plan.source.deletingLastPathComponent().path == plan.root.path,
            plan.sourceStamp.matchesIdentity(plan.source.path)
        else { throw FileCommitter.Failure.changedSinceScan }
        for (path, identity) in plan.destinationIdentities {
            guard identity.matches(URL(fileURLWithPath: path), directory: true) else {
                throw FileCommitter.Failure.changedSinceScan
            }
        }
        let identity = try OrganizationIdentity(of: plan.source, directory: false)
        guard identity.device == plan.rootIdentity.device else { throw POSIXError(.EXDEV) }
        try validateDirectories(
            to: plan.source.deletingLastPathComponent(), root: plan.root, identity: plan.rootIdentity)
    }

    static func contains(_ url: URL, in root: URL) -> Bool {
        url.path.hasPrefix(root.path + "/")
    }

    static func validateDirectories(to directory: URL, root: URL, identity: OrganizationIdentity) throws {
        guard directory.path == root.path || contains(directory, in: root), identity.matches(root, directory: true)
        else {
            throw FileCommitter.Failure.changedSinceScan
        }
        var ancestor = directory
        while true {
            let current = try OrganizationIdentity(of: ancestor, directory: true)
            guard try ancestor.resourceValues(forKeys: [.isPackageKey]).isPackage != true else {
                throw EngineError.invalidInput(.unsupportedFileType)
            }
            guard current.device == identity.device else { throw POSIXError(.EXDEV) }
            if ancestor.path == root.path { break }
            ancestor.deleteLastPathComponent()
        }
    }

    static func existingCategories(in root: URL) throws -> [String] {
        let maximumFolders = 32
        let maximumDepth = 2
        let rootDevice = try metadata(root).st_dev
        var pending: [(url: URL, path: String, depth: Int)] = [(root, "", 0)]
        var paths: [String] = []
        while !pending.isEmpty, paths.count < maximumFolders {
            let current = pending.removeFirst()
            let children = try FileManager.default.contentsOfDirectory(
                at: current.url,
                includingPropertiesForKeys: [.isPackageKey], options: .skipsHiddenFiles
            )
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                guard paths.count < maximumFolders else { break }
                let status = try metadata(child)
                guard status.st_mode & S_IFMT == S_IFDIR, status.st_dev == rootDevice,
                    try child.resourceValues(forKeys: [.isPackageKey]).isPackage != true
                else { continue }
                let path = current.path.isEmpty ? child.lastPathComponent : current.path + "/" + child.lastPathComponent
                guard OrganizationPolicy.isCategory(path) else { continue }
                paths.append(path)
                if current.depth + 1 < maximumDepth { pending.append((child, path, current.depth + 1)) }
            }
        }
        return paths
    }

    public static func candidates(in root: URL) throws -> [URL] {
        try validateRoot(root)
        return try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )
        .filter { try metadata($0).st_mode & S_IFMT == S_IFREG }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
