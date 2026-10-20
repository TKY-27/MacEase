import Engine
import Foundation
import MenuCatalog

/// Localized, actionable text for engine outcomes.
enum UserMessages {
    static func describe(_ error: EngineError, file: String) -> String {
        switch error {
        case .decodeFailed:
            String(localized: "“\(file)” could not be read.")
        case .encodeFailed:
            String(localized: "“\(file)” could not be converted.")
        case .commitFailed:
            String(localized: "“\(file)” could not be saved.")
        case .unsupportedCodec(let codec):
            String(localized: "“\(file)” uses \(codec), which MacEase does not support.")
        case .permissionDenied(let location):
            String(
                localized:
                    "MacEase needs access to \(describe(location)) to process “\(file)”. Allow it in System Settings > Privacy & Security."
            )
        case .cancelled:
            String(localized: "Cancelled.")
        case .targetUnreachable(let smallest):
            String(
                localized: "“\(file)” cannot get under the target size. The smallest result was \(byteCount(smallest))."
            )
        case .invalidInput(let reason):
            describe(reason, file: file)
        case .missingCapability(let capability):
            describe(capability)
        case .unexpected:
            String(localized: "Something went wrong with “\(file)”. Details are in the log.")
        }
    }

    static func describe(_ reason: SkipReason, file: String) -> String {
        switch reason {
        case .kindMismatch:
            String(localized: "“\(file)” does not contain what its name suggests.")
        case .isDirectory:
            String(localized: "“\(file)” is a folder.")
        case .notADirectory:
            String(localized: "“\(file)” is not a folder.")
        case .alreadyDone:
            String(localized: "“\(file)” needed no change.")
        case .outputNotSmaller:
            String(localized: "“\(file)” is already as small as it gets.")
        case .noUpscale:
            String(localized: "“\(file)” is already smaller than the requested size.")
        case .nothingToRemove:
            String(localized: "“\(file)” had nothing to remove.")
        case .changedSinceScan:
            String(
                localized: "“\(file)” changed after it was scanned, so it was kept.",
                comment: "Skip reason when a scanned duplicate or empty folder no longer qualifies"
            )
        case .noTextFound:
            String(localized: "No text was found in “\(file)”.")
        case .noTrashAvailable:
            String(localized: "“\(file)” is on a volume without a Trash.")
        case .undoTrashItemMissing:
            String(localized: "The original of “\(file)” is no longer in the Trash.")
        case .undoOutputChanged:
            String(localized: "“\(file)” changed after MacEase saved it.")
        case .undoOriginalOccupied:
            String(localized: "Another file now uses the name “\(file)”.")
        }
    }

    static func describe(_ warning: ItemWarning) -> String {
        switch warning {
        case .firstFrameOnly:
            String(localized: "Only the first frame was kept because the format has no animation.")
        case .firstPageOnly:
            String(localized: "Only the first page was kept.")
        case .loudnessLimitedByPeak(let reached):
            String(
                localized:
                    "Loudness stopped at \(reached.formatted(.number.precision(.fractionLength(1)))) LUFS to keep peaks below −1 dBTP."
            )
        case .keptAsDerived:
            String(localized: "The volume has no Trash, so the original was kept next to the result.")
        case .originalKept:
            String(localized: "The original could not be moved to the Trash, so both files were kept.")
        case .metadataDropped:
            String(localized: "The output format cannot hold the original metadata.")
        }
    }

    private static func describe(_ reason: InvalidInput, file: String) -> String {
        switch reason {
        case .tooLarge(let limit):
            String(localized: "“\(file)” is larger than \(byteCount(limit)).")
        case .notSquareEnough:
            String(localized: "“\(file)” is too small for an icon.")
        case .jsonSyntax(let line, let column):
            String(localized: "“\(file)” is not valid JSON (line \(line), column \(column)).")
        case .jsonNotFlatArray(let path):
            String(localized: "“\(file)” must be an array of flat objects; \(path) is not.")
        case .textEncodingUndetected:
            String(localized: "The text encoding of “\(file)” could not be detected.")
        case .unmappableCharacter(let line):
            String(localized: "“\(file)” has characters on line \(line) that Shift_JIS cannot represent.")
        case .emptyInput:
            String(localized: "“\(file)” is empty.")
        case .noPages:
            String(localized: "No pages were selected from “\(file)”.")
        case .encrypted:
            String(localized: "“\(file)” is password-protected.")
        case .tooFewFiles(let minimum):
            String(localized: "Select at least \(minimum) files for this operation.")
        case .malformed(let detail):
            String(localized: "“\(file)” could not be processed: \(detail).")
        case .passwordRequired:
            String(
                localized: "“\(file)” is protected by a password.",
                comment: "Archive extraction needs a password; the Password panel opens next"
            )
        case .wrongPassword:
            String(
                localized: "The password for “\(file)” is incorrect.",
                comment: "Archive extraction failed because the entered password is wrong"
            )
        case .unsafeArchivePath(let path):
            String(
                localized: "“\(file)” was not extracted because the entry “\(path)” points outside its folder.",
                comment: "Archive extraction refused a path traversal or absolute entry name"
            )
        case .archiveExpandsTooMuch(let limit):
            String(
                localized: "“\(file)” was not extracted because it expands to more than \(byteCount(limit)).",
                comment: "Archive extraction stopped by the zip bomb guard"
            )
        case .tooLong(let limit):
            String(
                localized:
                    "“\(file)” is longer than this preset allows (\(Duration.seconds(limit).formatted(.time(pattern: .minuteSecond)))).",
                comment: "Platform preset duration limit; the Trim panel opens next"
            )
        case .multipleTracks:
            String(
                localized:
                    "“\(file)” has multiple audio or video tracks. Replacement supports at most one of each.",
                comment: "Replacement would discard additional tracks"
            )
        }
    }

    private static func describe(_ capability: Capability) -> String {
        switch capability {
        case .appleIntelligence:
            String(localized: "Apple Intelligence is not available. Turn it on in System Settings.")
        case .java:
            String(localized: "No Java runtime was found. Install Java to decompile JAR files.")
        case .speechAssets:
            String(
                localized: "Speech recognition for this language is not installed yet. Try again after it downloads.")
        case .translationModel:
            String(
                localized:
                    "The translation languages are not downloaded. Download them in System Settings > General > Language & Region."
            )
        case .hardwareEncoder:
            String(localized: "This Mac has no hardware encoder for this format.")
        case .textRecognition:
            String(localized: "Text recognition is unavailable on this Mac.")
        }
    }

    private static func describe(_ location: PermissionLocation) -> String {
        switch location {
        case .desktop: String(localized: "the Desktop folder")
        case .documents: String(localized: "the Documents folder")
        case .downloads: String(localized: "the Downloads folder")
        case .removableVolume: String(localized: "removable volumes")
        case .networkVolume: String(localized: "network volumes")
        case .trash: String(localized: "the Trash (Full Disk Access)")
        case .other: String(localized: "this location")
        }
    }

    static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
    }
}

/// Title and body of the completion notification.
struct BatchSummary {
    let title: String
    let body: String
    let details: String

    init(_ outcome: BatchOutcome) {
        var succeeded = 0
        var skipped = 0
        var failed = 0
        var firstReason: String?
        var firstWarning: String?
        var reasons: [String] = []
        for (outcome, inputs) in zip(outcome.outcomes, outcome.inputs) {
            let file = inputs.first?.lastPathComponent ?? ""
            switch outcome {
            case .succeeded(_, let warnings):
                succeeded += 1
                if firstWarning == nil, let warning = warnings.first { firstWarning = UserMessages.describe(warning) }
                reasons += warnings.map {
                    String(
                        localized: "“\(file)”: \(UserMessages.describe($0))", comment: "File warning in batch results")
                }
            case .skipped(let reason):
                skipped += 1
                let message = UserMessages.describe(reason, file: file)
                if firstReason == nil { firstReason = message }
                reasons.append(message)
            case .failed(let error):
                failed += 1
                let message = UserMessages.describe(error, file: file)
                if firstReason == nil { firstReason = message }
                reasons.append(message)
            }
        }
        let operation = MenuStrings.operationName(outcome.operation)
        title =
            succeeded == 0 && failed > 0
            ? String(localized: "\(operation) failed", comment: "Notification title when every item failed")
            : operation
        var parts = [String(localized: "\(succeeded) done", comment: "Count of finished files")]
        if skipped > 0 { parts.append(String(localized: "\(skipped) skipped", comment: "Count of skipped files")) }
        if failed > 0 { parts.append(String(localized: "\(failed) failed", comment: "Count of failed files")) }
        let historyNote =
            outcome.historyFailed
            ? String(localized: "Undo is unavailable because the history could not be saved.") : nil
        let counts = parts.formatted(.list(type: .and))
        body = ([counts] + [firstReason ?? firstWarning, historyNote].compactMap { $0 })
            .joined(separator: "\n")
        details = ([counts] + reasons + [historyNote, outcome.reportText].compactMap { $0 }).joined(separator: "\n")
    }
}
