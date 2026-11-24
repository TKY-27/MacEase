import Darwin
import Foundation
import NativeShims
import os

struct MoveCopy {
    private static let logger = Logger(category: "move-copy")

    static func copy(_ source: URL, to destination: URL) throws {
        try Task.checkCancellation()
        var metadata = stat()
        guard lstat(source.path, &metadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        switch metadata.st_mode & S_IFMT {
        case S_IFDIR:
            guard mkdir(destination.path, S_IRWXU) == 0 else {
                throw EngineError.wrapping(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO), path: destination.path)
            }
            for name in try FileManager.default.contentsOfDirectory(atPath: source.path) {
                try copy(source.appending(path: name), to: destination.appending(path: name))
            }
        case S_IFREG, S_IFLNK:
            if metadata.st_flags & UInt32(SF_DATALESS) != 0 {
                var failure: NSError?
                NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: [], error: &failure) {
                    _ in
                }
                if let failure { throw failure }
            }
            if metadata.st_mode & S_IFMT == S_IFREG, access(source.path, R_OK) != 0 {
                throw EngineError.permissionDenied(PermissionLocation(path: source.path))
            }
            guard let state = copyfile_state_alloc() else { throw POSIXError(.ENOMEM) }
            defer { copyfile_state_free(state) }
            let status = macease_copyfile_set_callback(state) { _, _, _, _, _, _ in
                Task.isCancelled ? COPYFILE_QUIT : COPYFILE_CONTINUE
            }
            guard status == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let flags = copyfile_flags_t(COPYFILE_DATA | COPYFILE_NOFOLLOW | COPYFILE_EXCL)
            guard copyfile(source.path, destination.path, state, flags) == 0 else {
                try Task.checkCancellation()
                throw EngineError.wrapping(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO), path: destination.path)
            }
            if metadata.st_mode & S_IFMT == S_IFREG {
                let stream = try FileHandle(forWritingTo: destination)
                try stream.synchronize()
                try stream.close()
            }
        default:
            throw EngineError.invalidInput(.unsupportedFileType)
        }
    }

    static func verify(_ source: URL, copy: URL) throws {
        try Task.checkCancellation()
        var original = stat()
        var copied = stat()
        guard lstat(source.path, &original) == 0, lstat(copy.path, &copied) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard original.st_mode & S_IFMT == copied.st_mode & S_IFMT else {
            throw EngineError.commitFailed("Copied item type mismatch")
        }
        switch original.st_mode & S_IFMT {
        case S_IFLNK:
            guard
                try FileManager.default.destinationOfSymbolicLink(atPath: source.path)
                    == FileManager.default.destinationOfSymbolicLink(atPath: copy.path)
            else { throw EngineError.commitFailed("Copied symbolic link target mismatch") }
        case S_IFREG:
            guard original.st_size == copied.st_size, try StreamingText.equalContents(source, copy) else {
                throw EngineError.commitFailed("Copied file content mismatch")
            }
        case S_IFDIR:
            let originals = try FileManager.default.contentsOfDirectory(atPath: source.path).sorted()
            let copies = try FileManager.default.contentsOfDirectory(atPath: copy.path).sorted()
            guard originals == copies else { throw EngineError.commitFailed("Copied folder entries mismatch") }
            for name in originals { try verify(source.appending(path: name), copy: copy.appending(path: name)) }
        default:
            throw EngineError.invalidInput(.unsupportedFileType)
        }
    }

    static func preserveMetadata(_ source: URL, copy: URL) {
        do {
            var metadata = stat()
            guard lstat(source.path, &metadata) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if metadata.st_mode & S_IFMT == S_IFDIR {
                for name in try FileManager.default.contentsOfDirectory(atPath: source.path) {
                    preserveMetadata(source.appending(path: name), copy: copy.appending(path: name))
                }
            }
            let flags = copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW)
            guard copyfile(source.path, copy.path, nil, flags) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            logger.notice("Destination metadata unsupported: \(error.localizedDescription, privacy: .private)")
        }
    }
}
