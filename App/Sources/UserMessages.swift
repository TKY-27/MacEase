import Engine
import Foundation
import MenuCatalog

enum UserMessages {
    static func noteCount(_ count: Int) -> String {
        count == 1 ? String(localized: "1 note") : String(localized: "\(count) notes")
    }

    static func technicalDetail(_ error: EngineError) -> String? {
        switch error {
        case .decodeFailed(let detail), .encodeFailed(let detail), .commitFailed(let detail),
            .unexpected(let detail), .unsupportedCodec(let detail), .invalidInput(.malformed(let detail)):
            detail.isEmpty ? nil : detail
        default: nil
        }
    }

    static func describeResult(_ error: EngineError, file: String) -> String {
        if case .invalidInput(.malformed) = error {
            return String(
                localized:
                    "Couldn’t process “\(file)”: the input or settings could not be accepted. Check them and retry.")
        }
        return describe(error, file: file)
    }

    static func sizeChange(original: Int64, output: Int64) -> String {
        let fraction = Double(output - original) / Double(original)
        if fraction > 0 {
            return String(localized: "Size increased by \(fraction.formatted(.percent.precision(.fractionLength(1))))")
        }
        return String(localized: "Size reduced by \((-fraction).formatted(.percent.precision(.fractionLength(1))))")
    }

    static func describeActivity(_ error: Error) -> String {
        guard let reason = error as? ActivityAvailability else {
            return describe(EngineError.wrapping(error, path: ""), file: "")
        }
        switch reason {
        case .unsupported:
            return String(localized: "Comparison supports successful still-image compression and conversion only.")
        case .unavailable:
            return String(localized: "This result is no longer available in this Activity session.")
        case .missing(let file):
            return String(localized: "“\(file)” is missing. Select an existing file in Finder and run a new operation.")
        case .changed(let file):
            return String(localized: "“\(file)” changed since this operation. Run a new operation from Finder.")
        case .animatedOrMultipage:
            return String(localized: "Animated and multipage images cannot be compared.")
        }
    }

    static func describe(_ phase: ItemPhase) -> String {
        switch phase {
        case .queued: String(localized: "Queued")
        case .preparing: String(localized: "Preparing")
        case .convertingInput: String(localized: "Converting input")
        case .decoding: String(localized: "Decoding")
        case .searching: String(localized: "Finding target size")
        case .encoding: String(localized: "Encoding")
        case .optimizing: String(localized: "Optimizing PNG")
        case .verifying: String(localized: "Verifying")
        case .saving: String(localized: "Saving output")
        case .finished: String(localized: "Finished")
        case .downloading: String(localized: "Downloading")
        case .converting: String(localized: "Converting")
        }
    }

    private static func videoMetadataProperties(_ properties: [VideoMetadataProperty]) -> String {
        properties.map { property in
            switch property {
            case .descriptiveMetadata: String(localized: "video metadata")
            case .trackMetadata: String(localized: "track metadata")
            case .language: String(localized: "track language")
            case .volume: String(localized: "track volume")
            case .enabledState: String(localized: "track enabled state")
            case .alternateGroups: String(localized: "alternate track groups")
            }
        }.formatted(.list(type: .and))
    }

    static func unpreservedStreams(_ streams: [UnpreservedStream], titleCase: Bool = false) -> String {
        streams.map { stream in
            let name =
                switch stream {
                case .video: String(localized: "extra video", comment: "Video tracks after the first")
                case .audio: String(localized: "extra audio", comment: "Audio tracks after the first")
                case .subtitle: String(localized: "subtitles")
                case .closedCaption: String(localized: "closed captions")
                case .timecode: String(localized: "timecode")
                case .chapter: String(localized: "chapters")
                case .attachment: String(localized: "attachments")
                case .metadata: String(localized: "timed metadata")
                case .data: String(localized: "other data")
                }
            return titleCase ? name.localizedCapitalized : name
        }.formatted(.list(type: .and))
    }

    /// Effect of leaving one kind out.
    static func consequence(of stream: UnpreservedStream, operation: OperationID? = nil) -> String {
        if stream == .audio {
            switch operation {
            case .videoRemoveAudio:
                return String(localized: "Extra audio: all audio tracks are removed.")
            case .videoThumbnail, .videoToGIF, .videoToAPNG, .videoToAnimatedWebP, .videoSubtitles, .audioSubtitles:
                return String(localized: "Extra audio: the output contains no audio tracks.")
            case .audioEnhance:
                return String(localized: "Extra audio: only the first audio track is used to create the output.")
            default: break
            }
        }
        if stream == .video {
            switch operation {
            case .videoExtractAudio, .videoSubtitles, .audioConvert, .audioCompress, .audioNormalize, .audioTrim,
                .audioEnhance, .audioSubtitles:
                return String(localized: "Extra video: the output contains no video tracks.")
            case .videoThumbnail, .videoToGIF, .videoToAPNG, .videoToAnimatedWebP:
                return String(localized: "Extra video: only the first video track is used to create the output.")
            default: break
            }
        }
        return switch stream {
        case .video: String(localized: "Extra video: only the first video track is kept.")
        case .audio: String(localized: "Extra audio: only the first audio track is kept.")
        case .subtitle: String(localized: "Subtitles: they can no longer be turned on during playback.")
        case .closedCaption: String(localized: "Closed captions: they can no longer be turned on during playback.")
        case .timecode:
            String(
                localized:
                    "Timecode: editing apps use it to line up clips. Leaving it out doesn’t affect picture or sound.")
        case .chapter: String(localized: "Chapters: you can no longer jump from chapter to chapter.")
        case .attachment:
            String(localized: "Attachments: files stored inside, such as cover art or fonts, are left out.")
        case .metadata:
            String(localized: "Timed metadata: details that change over time, such as location, are left out.")
        case .data:
            String(
                localized:
                    "Other data: things like markers or sensor readings are left out. Most players don’t use them.")
        }
    }

    static func streamsStatement(file: String, streams: [UnpreservedStream]) -> String {
        String(localized: "“\(file)” contains \(unpreservedStreams(streams)), which MacEase can’t carry over.")
    }

    static var streamsListIntroduction: String {
        String(localized: "These files contain content MacEase can’t carry over:")
    }

    static func streamsListLine(file: String, streams: [UnpreservedStream]) -> String {
        String(localized: "“\(file)”: \(unpreservedStreams(streams))")
    }

    static func confirmationCount(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 file needs your confirmation.", comment: "Activity status")
            : String(localized: "\(count) files need your confirmation.", comment: "Activity status")
    }

    static func continueWithout(_ streams: [UnpreservedStream]) -> String {
        streams.count > namedStreamLimit
            ? String(localized: "Continue Without Them", comment: "Runs the operation, leaving the listed content out")
            : String(
                localized: "Continue Without \(unpreservedStreams(streams, titleCase: true))",
                comment: "Runs the operation, leaving the named content out")
    }

    /// Longer lists make buttons unreadable.
    static let namedStreamLimit = 2

    static func streamOmissionConsequence(files: [String], replacesOriginals: Bool) -> String {
        switch (replacesOriginals, files.count == 1 ? files.first : nil) {
        case (true, let file?):
            String(
                localized:
                    "If you continue, “\(file)” is replaced. The original moves to the Trash, and you can undo this.")
        case (true, nil):
            String(
                localized:
                    "If you continue, these \(files.count) files are replaced. The originals move to the Trash, and you can undo this."
            )
        case (false, let file?):
            String(localized: "If you continue, a new file is made and “\(file)” stays as it is.")
        case (false, nil):
            String(localized: "If you continue, new files are made and the originals stay as they are.")
        }
    }

    static func continuedWithout(_ streams: [UnpreservedStream]) -> String {
        String(
            localized: "Continued without \(unpreservedStreams(streams)). The new result is below.",
            comment: "Activity note after the user agreed to leave content out")
    }

    private static func metadataClasses(_ fields: [MetadataField]) -> String {
        fields.map { field in
            switch field {
            case .exif, .gps, .makerNotes, .comments: "EXIF"
            case .xmp: "XMP"
            case .iptc: "IPTC"
            }
        }.formatted(.list(type: .and))
    }

    static func describe(_ error: EngineError, file: String) -> String {
        switch error {
        case .retryInputMissing:
            String(localized: "“\(file)” is missing. Select an existing file in Finder and run a new operation.")
        case .retryInputChanged:
            String(localized: "“\(file)” changed since this operation. Run a new operation from Finder.")
        case .decodeFailed:
            String(
                localized:
                    "Couldn’t read “\(file)”: decoding failed. Check that the file opens in another app, then retry.")
        case .protectionAuthenticationFailed:
            String(
                localized:
                    "Couldn’t unlock “\(file)”: the password is incorrect or the file is damaged. Check the password or use an intact copy."
            )
        case .protectionDiskFull:
            String(localized: "Couldn’t protect “\(file)”: there is not enough disk space. Free up space, then retry.")
        case .insufficientDiskSpace(let required, let available):
            String(
                localized:
                    "Couldn’t process “\(file)”: not enough disk space (needs about \(byteCount(required)), \(byteCount(available)) available). Free up space and retry."
            )
        case .fallbackToolMissing:
            String(
                localized:
                    "Couldn’t read “\(file)”: the media converter component is missing. Reinstall MacEase and retry."
            )
        case .nonFiniteAudioSample:
            String(
                localized:
                    "Couldn’t read “\(file)”: its audio contains invalid samples. Export a new copy in another audio app."
            )
        case .encodeFailed:
            String(
                localized:
                    "Couldn’t convert “\(file)”: encoding failed. Try another output format or different settings.")
        case .commitFailed:
            String(
                localized:
                    "Couldn’t save “\(file)”: saving failed. Check free disk space and folder access, then retry.")
        case .historyPersistenceFailed:
            String(
                localized:
                    "Further file changes were stopped because undo history could not be saved. Check free disk space and access to the history folder, then retry.",
                comment: "Avoids implying earlier commits were rolled back"
            )
        case .unsupportedCodec:
            String(
                localized:
                    "Couldn’t convert “\(file)”: the codec is unsupported. Choose a supported format or convert it in another app."
            )
        case .audioChannelLayoutUnsupported:
            String(
                localized:
                    "Couldn’t convert “\(file)”: this format cannot preserve its audio channel layout. Choose another output format."
            )
        case .audioCopyUnsupported:
            String(localized: "This audio cannot be extracted unchanged. Choose an explicit conversion format.")
        case .audioCopyTimingUnsupported:
            String(localized: "This audio timing cannot be copied unchanged. Choose a lossless conversion format.")
        case .audioMetadataUnsupported:
            String(
                localized:
                    "“\(file)” cannot replace the original because its audio metadata cannot be preserved. Choose Save as New File.",
                comment: "Refuses audio metadata loss on replacement"
            )
        case .imageGainMapUnsupported:
            String(
                localized:
                    "Couldn’t edit “\(file)”: its HDR gain map cannot be preserved. Convert a copy to SDR before editing."
            )
        case .imageSequenceUnsupported:
            String(
                localized:
                    "Couldn’t convert “\(file)”: this format cannot preserve every frame or page. Choose a format that supports the full sequence."
            )
        case .imageLoopCountUnsupported:
            String(
                localized:
                    "Couldn’t convert “\(file)”: its animation loop count cannot be preserved. Choose another animation format."
            )
        case .imageTransparencyUnsupported:
            String(
                localized:
                    "“\(file)” cannot replace the original because the output would lose transparency. Choose Save as New File to flatten onto the configured background color."
            )
        case .imageHDRUnsupported:
            String(
                localized:
                    "“\(file)” cannot replace the original because the output would lose HDR. Choose Save as New File or Convert > SDR to tone-map it to SDR."
            )
        case .imageMetadataUnsupported(let fields):
            String(
                localized:
                    "“\(file)” cannot replace the original because the output would lose \(metadataClasses(fields)) metadata. Choose Save as New File."
            )
        case .hdrConversionUnsupported:
            String(
                localized:
                    "Couldn’t convert “\(file)” to SDR: this HDR content is unsupported. Export an SDR copy in another app."
            )
        case .sdrVerificationFailed:
            String(
                localized: "Couldn’t convert “\(file)” to SDR: output verification failed. Try another output format.")
        case .videoAlphaUnsupported:
            String(
                localized:
                    "“\(file)” cannot preserve transparency in this output. Choose Save as New File to flatten onto the video background color."
            )
        case .videoHDRUnsupported:
            String(
                localized:
                    "“\(file)” cannot replace the original because the output would lose HDR. Choose Save as New File or Convert > SDR to tone-map it to SDR."
            )
        case .videoDolbyVisionUnsupported:
            String(
                localized:
                    "“\(file)” cannot replace the original because the output would lose Dolby Vision dynamic metadata. Choose Save as New File.",
                comment: "Refuses Dolby Vision metadata loss")
        case .videoMetadataUnsupported(let properties):
            String(
                localized:
                    "“\(file)” cannot replace the original because the output would lose \(videoMetadataProperties(properties)). Choose Save as New File."
            )
        case .videoDisplayTransformUnsupported:
            String(
                localized:
                    "Couldn’t edit “\(file)”: its video display transform is unsupported. Export a new copy in another video app."
            )
        case .duplicateArchiveRootName(let name):
            String(
                localized: "Multiple selected folders are named “\(name)”. Rename one before creating the archive.",
                comment: "Archive roots must remain distinguishable"
            )
        case .permissionDenied(let location):
            String(
                localized:
                    "MacEase needs access to \(describe(location)) to process “\(file)”. Allow it in System Settings > Privacy & Security."
            )
        case .cancelled:
            String(localized: "Cancelled.")
        case .targetUnreachable(let smallest):
            String(
                localized:
                    "Couldn’t compress “\(file)” below the target: the smallest result was \(byteCount(smallest)). Choose a larger target size."
            )
        case .pngTargetNotReached:
            String(
                localized:
                    "“\(file)” could not reach the target size with these settings. Try a larger target size."
            )
        case .invalidInput(let reason):
            describe(reason, file: file)
        case .missingCapability(let capability):
            describe(capability)
        case .unexpected:
            String(
                localized:
                    "Couldn’t process “\(file)”: an unexpected error occurred. Retry, or report the error with its details."
            )
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
        case .alreadySDR:
            String(localized: "“\(file)” is already SDR and was kept without re-encoding.")
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
        case .documentLayoutChanged:
            String(
                localized:
                    "Basic text and formatting kept; pagination, fields and revisions may change. TXT omits formatting and attachments."
            )
        case .htmlOfflineContent:
            String(
                localized:
                    "Scripts and external resources omitted. PDF uses one continuous page; TXT keeps rendered text only."
            )
        case .structuredTextFormattingLost:
            String(
                localized:
                    "Supported values kept; comments, key order and source formatting omitted.")
        case .imageFlattened:
            String(
                localized:
                    "PSD layers flattened using the stored composite image.")
        case .imageTransparencyFlattened:
            String(
                localized:
                    "Transparency flattened onto the configured background color."
            )
        case .imageToneMappedToSDR:
            String(
                localized: "HDR tone-mapped to SDR: this output cannot preserve HDR.")
        case .videoToneMappedToSDR:
            String(
                localized: "HDR tone-mapped to SDR: this output cannot preserve HDR.")
        case .videoTransparencyFlattened:
            String(
                localized: "Transparency flattened onto the video background color.")
        case .videoMetadataDropped(let properties):
            String(
                localized:
                    "Not kept: this output cannot preserve \(videoMetadataProperties(properties)).")
        case .streamsOmitted(let streams):
            String(
                localized:
                    "Left out, as you confirmed: \(unpreservedStreams(streams)).")
        case .imageMetadataDropped(let fields):
            String(
                localized:
                    "Metadata not kept: this format cannot store \(metadataClasses(fields))."
            )
        case .markdownUnsafeContentOmitted:
            String(localized: "Raw HTML, scripts and unsafe links omitted.")
        case .pngOptimizationSkipped:
            String(
                localized:
                    "Optional lossless PNG optimization skipped to stay within the memory budget."
            )
        case .imagePaletteReduced(let colors):
            String(localized: "Palette reduced to at most \(colors) colors.")
        case .imageDimensionsReduced:
            String(localized: "Image dimensions reduced.")
        case .unmappableCharactersReplaced:
            String(localized: "Characters unsupported by Shift_JIS replaced using the saved policy.")
        case .loudnessLimitedByPeak(let reached):
            String(
                localized:
                    "Loudness limited to \(reached.formatted(.number.precision(.fractionLength(1)))) LUFS to keep peaks below −1 dBTP."
            )
        case .keptAsDerived:
            String(localized: "Saved as a new file: this volume has no Trash.")
        case .copiedAcrossVolumes(let original, let destination):
            String(localized: "Copied to another disk at \(destination.path). Original kept at \(original.path).")
        case .originalKept:
            String(localized: "Both files kept: the original could not be moved to the Trash.")
        case .outputNameUnchanged:
            String(
                localized:
                    "Filename capitalization unchanged: renaming failed after saving.",
                comment: "Replacement succeeded before renaming failed"
            )
        case .metadataDropped:
            String(localized: "Metadata not kept: this output format cannot store it.")
        case .archiveFolderAttributesNotRestored:
            String(localized: "Some extracted folders use default permissions and modified times.")
        case .hdrProvenanceUnknown:
            String(localized: "Source signals HDR; capture or expansion origin unknown.")
        case .dolbyVisionRemoved:
            String(
                localized: "Dolby Vision dynamic metadata omitted.",
                comment: "Discloses Dolby Vision metadata loss")
        }
    }

    private static func describe(_ reason: InvalidInput, file: String) -> String {
        switch reason {
        case .tooLarge(let limit):
            String(localized: "Couldn’t process “\(file)”: it exceeds \(byteCount(limit)). Choose a smaller file.")
        case .notSquareEnough:
            String(localized: "Couldn’t create an icon from “\(file)”: the image is too small. Choose a larger image.")
        case .jsonSyntax(let line, let column):
            String(
                localized:
                    "Couldn’t read “\(file)”: invalid JSON at line \(line), column \(column). Correct the syntax, then retry."
            )
        case .jsonNotFlatArray(let path):
            String(
                localized:
                    "Couldn’t convert “\(file)”: \(path) is not a flat object array. Use an array of flat objects.")
        case .textEncodingUndetected:
            String(localized: "Couldn’t read “\(file)”: its text encoding is unknown. Save a UTF-8 copy, then retry.")
        case .unmappableCharacter(let line):
            String(
                localized:
                    "Couldn’t convert “\(file)”: line \(line) contains characters unsupported by Shift_JIS. Use UTF-8 or allow character replacement."
            )
        case .emptyInput:
            String(localized: "Couldn’t process “\(file)”: the file is empty. Choose a file with content.")
        case .noPages:
            String(localized: "Couldn’t process “\(file)”: no pages were selected. Select at least one page.")
        case .encrypted:
            String(localized: "Couldn’t process “\(file)”: it is password-protected. Unlock a copy before retrying.")
        case .pdfCopyingNotAllowed:
            String(localized: "“\(file)” does not allow copying. Ask the PDF owner for a copy with permission.")
        case .pdfPrintingNotAllowed:
            String(localized: "“\(file)” does not allow printing. Ask the PDF owner for a copy with permission.")
        case .unsupportedVideoPreset:
            String(
                localized:
                    "The video preset for “\(file)” is unsupported. Use MP4, MOV or M4V with H.264 or HEVC and AAC; WebM with VP9 and Opus; or MKV with H.264, HEVC or VP9 and AAC or Opus."
            )
        case .tooFewFiles(let minimum):
            String(localized: "Select at least \(minimum) files for this operation.")
        case .malformed(let detail):
            String(localized: "Couldn’t process “\(file)”: \(detail). Check the input and settings, then retry.")
        case .passwordRequired:
            String(
                localized: "Couldn’t extract “\(file)”: a password is required. Enter the archive password."
            )
        case .wrongPassword:
            String(
                localized: "Couldn’t extract “\(file)”: the password is incorrect. Check the password, then retry."
            )
        case .unsafeArchivePath(let path):
            String(
                localized:
                    "Couldn’t extract “\(file)”: entry “\(path)” points outside its folder. Use an archive with safe relative paths."
            )
        case .archiveExpandsTooMuch(let limit):
            String(
                localized:
                    "Couldn’t extract “\(file)”: expanded content exceeds \(byteCount(limit)). Use a smaller archive."
            )
        case .tooLong(let limit):
            String(
                localized:
                    "Couldn’t process “\(file)”: it exceeds this preset’s duration limit (\(Duration.seconds(limit).formatted(.time(pattern: .minuteSecond)))). Trim it or choose another preset."
            )
        case .multipleTracks:
            String(
                localized:
                    "Couldn’t process “\(file)”: only one audio and one video track are supported. Export a copy with those tracks in another app.",
                comment: "Replacement would discard additional tracks"
            )
        case .unpreservedStreams(let streams) where !streams.isEmpty:
            String(
                localized:
                    "Couldn’t process “\(file)”: it contains \(unpreservedStreams(streams)), which MacEase can’t carry over. Nothing was changed."
            )
        case .unpreservedStreams:
            String(
                localized:
                    "Couldn’t process “\(file)”: it contains content MacEase can’t carry over. Nothing was changed.")
        case .frameMemoryExceeded:
            String(
                localized: "“\(file)” exceeds the frame memory budget. Use fewer or smaller frames.",
                comment: "Limit protects available memory"
            )
        case .chainedStream:
            String(
                localized:
                    "Couldn’t read “\(file)”: chained Ogg streams are unsupported. Split the streams in another app before retrying."
            )
        case .unsupportedFileType:
            String(localized: "“\(file)” is not a regular file or folder. Select a regular file or folder.")
        case .invalidAnimationRange:
            String(
                localized: "Choose an animation range within “\(file)” and a supported frame rate.",
                comment: "Range must fit the source"
            )
        case .invalidNumericParameter:
            String(localized: "Choose finite numeric values within the supported range.")
        case .externalMediaReference:
            String(
                localized:
                    "This file refers to media in another file, so MacEase can't open it. Export a self-contained copy in the app that made it."
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
            String(
                localized:
                    "Couldn’t encode: this Mac has no hardware encoder for this format. Choose another output format.")
        case .textRecognition:
            String(
                localized:
                    "Couldn’t recognize text: recognition is unavailable on this Mac. Try another text recognition app."
            )
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

struct BatchSummary {
    let title: String
    let body: String
    let details: String

    init(_ outcome: BatchOutcome) {
        var succeeded = 0
        var skipped = 0
        var failed = 0
        var firstReason: String?
        var noteCount = 0
        var reasons: [String] = []
        for (result, inputs) in zip(outcome.outcomes, outcome.inputs) {
            let file = inputs.first?.lastPathComponent ?? ""
            switch result {
            case .succeeded(_, let warnings):
                succeeded += 1
                noteCount += Set(warnings.map { UserMessages.describe($0) }).count
                reasons += warnings.map {
                    String(
                        localized: "“\(file)”: \(UserMessages.describe($0))", comment: "File warning in batch results")
                }
            case .skipped(let reason):
                skipped += 1
                let message = UserMessages.describe(reason, file: file)
                if firstReason == nil { firstReason = message }
                reasons.append(message)
            case .failed(let error) where error == .cancelled && outcome.operation == .archiveHatchExtract:
                let message = String(localized: "Paused.")
                if firstReason == nil { firstReason = message }
                reasons.append(message)
            case .failed(let error):
                failed += 1
                let message = UserMessages.describeResult(error, file: file)
                if firstReason == nil { firstReason = message }
                // Malformed-input text already carries its detail.
                let detail: String? =
                    switch error {
                    case .invalidInput(.malformed): nil
                    default: UserMessages.technicalDetail(error)
                    }
                reasons.append(
                    [UserMessages.describe(error, file: file), detail].compactMap { $0 }.joined(separator: " "))
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
        if noteCount > 0 { parts.append(UserMessages.noteCount(noteCount)) }
        let historyNote =
            outcome.historyFailed
            ? String(localized: "Undo is unavailable because the history could not be saved.") : nil
        let counts = parts.formatted(.list(type: .and))
        body = ([counts] + [firstReason, historyNote].compactMap { $0 })
            .joined(separator: "\n")
        details = ([counts] + reasons + [historyNote, outcome.reportText].compactMap { $0 }).joined(separator: "\n")
    }
}
