import Formats
import Foundation
import MenuCatalog

/// The host localizes these per file.
public enum EngineError: Error, Equatable, Sendable {
    case decodeFailed(String)
    case encodeFailed(String)
    case commitFailed(String)
    case unsupportedCodec(String)
    case duplicateArchiveRootName(String)
    case permissionDenied(PermissionLocation)
    case cancelled
    case targetUnreachable(smallestBytes: Int64)
    case invalidInput(InvalidInput)
    case missingCapability(Capability)
    case unexpected(String)
}

public enum PermissionLocation: String, Codable, Sendable {
    case desktop
    case documents
    case downloads
    case removableVolume
    case networkVolume
    case trash
    case other

    public init(path: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home + "/Desktop/") {
            self = .desktop
        } else if path.hasPrefix(home + "/Documents/") {
            self = .documents
        } else if path.hasPrefix(home + "/Downloads/") {
            self = .downloads
        } else if path.hasPrefix(home + "/.Trash/") || path.contains("/.Trashes/") {
            self = .trash
        } else if path.hasPrefix("/Volumes/") {
            // Unreadable volumes are reported as removable.
            let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsLocalKey])
            self = values?.volumeIsLocal == false ? .networkVolume : .removableVolume
        } else {
            self = .other
        }
    }
}

public enum InvalidInput: Equatable, Sendable {
    case tooLarge(limitBytes: Int64)
    case notSquareEnough
    case jsonSyntax(line: Int, column: Int)
    case jsonNotFlatArray(path: String)
    case textEncodingUndetected
    case unmappableCharacter(line: Int)
    case emptyInput
    case noPages
    case encrypted
    case tooFewFiles(minimum: Int)
    case malformed(String)
    case passwordRequired
    case wrongPassword
    case unsafeArchivePath(String)
    case archiveExpandsTooMuch(limitBytes: Int64)
    case tooLong(limitSeconds: Double)
    case multipleTracks
    case frameMemoryExceeded
    case invalidAnimationRange
}

public enum Capability: String, Equatable, Sendable {
    case appleIntelligence
    case java
    case speechAssets
    case translationModel
    case hardwareEncoder
    case textRecognition
}

public enum SkipReason: Equatable, Sendable {
    case kindMismatch(expected: FileKind)
    case isDirectory
    case notADirectory
    case alreadyDone
    case outputNotSmaller
    case noUpscale
    case nothingToRemove
    case changedSinceScan
    case noTextFound
    case noTrashAvailable
    case undoTrashItemMissing
    case undoOutputChanged
    case undoOriginalOccupied
}

extension EngineError {
    init(_ format: FormatError) {
        switch format {
        case .unsupported(let name): self = .unsupportedCodec(name)
        case .corrupt(let detail), .decoderFailure(let detail): self = .decodeFailed(detail)
        case .encoderFailure(let detail): self = .encodeFailed(detail)
        case .io(let detail): self = .unexpected(detail)
        }
    }

    public static func wrapping(
        _ error: any Error,
        path: String,
        otherwise: (String) -> EngineError = EngineError.unexpected
    ) -> EngineError {
        if let engineError = error as? EngineError { return engineError }
        if let archiveError = error as? ArchiveError { return ArchivePlanner.engineError(archiveError) }
        if let format = error as? FormatError { return EngineError(format) }
        if error is CancellationError { return .cancelled }
        let nsError = error as NSError
        if isPermissionError(nsError)
            || (nsError.userInfo[NSUnderlyingErrorKey] as? NSError).map(isPermissionError) == true
        {
            return .permissionDenied(PermissionLocation(path: path))
        }
        return otherwise("\(nsError.domain) \(nsError.code)")
    }

    private static func isPermissionError(_ error: NSError) -> Bool {
        switch error.domain {
        case NSCocoaErrorDomain: [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code)
        case NSPOSIXErrorDomain: [Int(EPERM), Int(EACCES)].contains(error.code)
        default: false
        }
    }
}
