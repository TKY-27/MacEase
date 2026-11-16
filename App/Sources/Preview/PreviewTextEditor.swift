import AppKit
import Engine
import Observation

@MainActor
@Observable
final class PreviewTextEditor {
    private(set) var url: URL?
    private(set) var document: TextEditDocument?
    private(set) var stamp: FileStamp?
    private(set) var baseline = ""
    var buffer = ""
    private(set) var editing = false
    private(set) var saving = false
    var message: String?
    var offersUTF8 = false
    var confirming = false
    @ObservationIgnored let undo = UndoManager()
    @ObservationIgnored private var savedTask: Task<Void, Never>?

    var dirty: Bool { !buffer.utf8.elementsEqual(baseline.utf8) }
    var pinsSelection: Bool { dirty || saving || confirming }

    func begin(url: URL, source: PreviewTextSource, encoding: PreviewEncoding) throws {
        guard !pinsSelection, !source.truncated, !source.binaryPropertyList, let stamp = source.stamp else { return }
        let document = try TextEditDocument(
            bytes: source.bytes, encoding: encoding == .automatic ? nil : encoding.foundation)
        self.url = url
        self.document = document
        self.stamp = stamp
        baseline = document.text
        buffer = document.text
        editing = true
        message = nil
        undo.removeAllActions()
    }

    func discard() {
        guard !saving else { return }
        buffer = baseline
        message = nil
        offersUTF8 = false
        undo.removeAllActions()
    }

    func reset() {
        guard !pinsSelection else { return }
        savedTask?.cancel()
        url = nil
        document = nil
        stamp = nil
        baseline = ""
        buffer = ""
        editing = false
        message = nil
        offersUTF8 = false
        undo.removeAllActions()
    }

    func prepareSave(asUTF8: Bool = false) -> Batch? {
        guard dirty, !saving, let url, let stamp, let document else { return nil }
        savedTask?.cancel()
        message = nil
        offersUTF8 = false
        let batch = TextReplacement.batch(original: url, stamp: stamp, text: buffer, document: document, asUTF8: asUTF8)
        saving = true
        return batch
    }

    func finishSave(_ result: ItemOutcome, stamp: FileStamp?, historyFailed: Bool, asUTF8: Bool) -> Bool {
        saving = false
        guard let url else { return false }
        switch result {
        case .failed(let error):
            message = UserMessages.describeResult(error, file: url.lastPathComponent)
            offersUTF8 = error == .invalidInput(.textEditUnrepresentable)
        case .skipped(let reason):
            message = UserMessages.describe(reason, file: url.lastPathComponent)
        case .succeeded(let outputs, let warnings):
            guard outputs == [url], warnings.isEmpty else {
                message = String(
                    localized: "Saved as a separate file; the original is unchanged. Discard to leave this buffer.")
                return false
            }
            self.stamp = stamp
            guard !historyFailed, stamp != nil else {
                message = UserMessages.describeResult(.historyPersistenceFailed, file: url.lastPathComponent)
                return false
            }
            if asUTF8 {
                do { document = try TextEditDocument(bytes: Data(buffer.utf8)) } catch {
                    message = UserMessages.describeResult(
                        EngineError.wrapping(error, path: url.path), file: url.lastPathComponent)
                    return false
                }
            }
            baseline = buffer
            message = String(localized: "Saved")
            savedTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                self?.message = nil
            }
            return true
        }
        return false
    }

    func save(using jobs: JobCenter, asUTF8: Bool = false) async -> Bool {
        guard let batch = prepareSave(asUTF8: asUTF8) else { return !dirty && !saving }
        let outcome = await jobs.run(batch: batch).value
        var committedStamp: FileStamp?
        if let outcome {
            for record in outcome.record?.items ?? [] {
                if case .replaced(_, _, _, let stamp, _) = record { committedStamp = stamp }
            }
        }
        return finishSave(
            outcome?.outcomes.first ?? .failed(.cancelled), stamp: committedStamp,
            historyFailed: outcome?.historyFailed ?? false, asUTF8: asUTF8)
    }
}
