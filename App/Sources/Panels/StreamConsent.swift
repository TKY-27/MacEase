import Engine
import SwiftUI

/// Consent asked before a panel opens or runs media.
struct StreamConsentRequest: Identifiable {
    enum Purpose: Equatable {
        case open
        case add([URL])
        case proceed
    }

    struct File: Equatable {
        let url: URL
        let omission: StreamOmission

        var streams: [UnpreservedStream] { UnpreservedStream.allCases.filter(omission.streams.contains) }
        var name: String { url.lastPathComponent }
    }

    let id = UUID()
    let purpose: Purpose
    let files: [File]

    var streams: [UnpreservedStream] {
        let combined = Set(files.flatMap(\.streams))
        return UnpreservedStream.allCases.filter(combined.contains)
    }

    /// `stamp` must predate the inspection.
    static func blockedFile(by error: Error, at url: URL, stamp: MediaSourceStamp) -> File? {
        guard case .invalidInput(.unpreservedStreams(let streams)) = EngineError.wrapping(error, path: url.path),
            !streams.isEmpty
        else { return nil }
        return File(url: url, omission: StreamOmission(stamp: stamp, streams: Set(streams)))
    }

    var title: String {
        let names = UserMessages.unpreservedStreams(streams)
        switch (purpose, files.count == 1 ? files.first : nil) {
        case (.open, let file?): return String(localized: "Open “\(file.name)” without \(names)?")
        case (.open, nil):
            return String(localized: "Open \(files.count) videos without content MacEase can’t carry over?")
        case (.add, let file?): return String(localized: "Add “\(file.name)” without \(names)?")
        case (.add, nil):
            return String(localized: "Add \(files.count) videos without content MacEase can’t carry over?")
        case (.proceed, _) where streams.count <= UserMessages.namedStreamLimit:
            return String(localized: "Continue without \(names)?")
        case (.proceed, _): return String(localized: "Continue without content MacEase can’t carry over?")
        }
    }

    var message: String {
        let found =
            files.count == 1
            ? UserMessages.streamsStatement(file: files[0].name, streams: files[0].streams)
            : ([UserMessages.streamsListIntroduction]
                + files.map { UserMessages.streamsListLine(file: $0.name, streams: $0.streams) })
                .joined(separator: "\n")
        return [found, streams.map(UserMessages.consequence(of:)).joined(separator: "\n"), originalsNote]
            .joined(separator: "\n\n")
    }

    private var originalsNote: String {
        switch (purpose, files.count == 1 ? files.first : nil) {
        case (.open, let file?): String(localized: "Opening doesn’t change “\(file.name)”.")
        case (.open, nil): String(localized: "Opening doesn’t change the originals.")
        case (.add, let file?): String(localized: "Adding doesn’t change “\(file.name)”.")
        case (.add, nil): String(localized: "Adding doesn’t change the originals.")
        case (.proceed, _): String(localized: "Your originals stay as they are.")
        }
    }

    var actionTitle: String {
        let names = UserMessages.unpreservedStreams(streams, titleCase: true)
        let named = streams.count <= UserMessages.namedStreamLimit
        return switch purpose {
        case .open:
            named
                ? String(localized: "Open Without \(names)", comment: "Opens media, leaving the named content out")
                : String(localized: "Open Without Them", comment: "Opens media, leaving the listed content out")
        case .add:
            named
                ? String(localized: "Add Without \(names)", comment: "Adds media, leaving the named content out")
                : String(localized: "Add Without Them", comment: "Adds media, leaving the listed content out")
        case .proceed: UserMessages.continueWithout(streams)
        }
    }
}

extension View {
    func streamConsentAlert(
        _ request: Binding<StreamConsentRequest?>, accept: @escaping (StreamConsentRequest) -> Void,
        decline: @escaping (StreamConsentRequest) -> Void
    ) -> some View {
        alert(
            Text(request.wrappedValue?.title ?? ""),
            isPresented: Binding(
                get: { request.wrappedValue != nil },
                set: { if !$0 { request.wrappedValue = nil } }),
            presenting: request.wrappedValue
        ) { presented in
            Button(presented.actionTitle) { accept(presented) }
            Button("Cancel", role: .cancel) { decline(presented) }
        } message: { presented in
            Text(presented.message)
        }
    }
}
