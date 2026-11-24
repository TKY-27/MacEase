import Engine
import SwiftUI

/// Consent asked before opening or adding media.
struct StreamConsentRequest: Identifiable {
    enum Purpose: Equatable {
        case open
        case add([URL])
    }

    struct File: Equatable {
        let url: URL
        let streams: [UnpreservedStream]
    }

    let id = UUID()
    let purpose: Purpose
    let files: [File]

    var streams: [UnpreservedStream] {
        let combined = Set(files.flatMap(\.streams))
        return UnpreservedStream.allCases.filter(combined.contains)
    }

    static func blockedStreams(in error: Error, at url: URL) -> [UnpreservedStream]? {
        guard case .invalidInput(.unpreservedStreams(let streams)) = EngineError.wrapping(error, path: url.path),
            !streams.isEmpty
        else { return nil }
        return streams
    }

    var title: String {
        let names = UserMessages.unpreservedStreams(streams)
        switch (purpose, files.count == 1 ? files.first : nil) {
        case (.open, let file?):
            return String(localized: "Open “\(file.url.lastPathComponent)” without \(names)?")
        case (.open, nil):
            return String(localized: "Open \(files.count) videos without the streams MacEase can’t keep?")
        case (.add, let file?):
            return String(localized: "Add “\(file.url.lastPathComponent)” without \(names)?")
        case (.add, nil):
            return String(localized: "Add \(files.count) videos without the streams MacEase can’t keep?")
        }
    }

    var message: String {
        guard files.count > 1 else {
            let file = files[0].url.lastPathComponent
            let names = UserMessages.unpreservedStreams(streams)
            return purpose == .open
                ? String(
                    localized:
                        "MacEase can’t keep \(names) in an edited file, so the file you save won’t include them. Opening doesn’t change “\(file)”."
                )
                : String(
                    localized:
                        "MacEase can’t keep \(names) in an edited file, so the file you save won’t include them. Adding doesn’t change “\(file)”."
                )
        }
        let lines = files.map { file in
            String(localized: "“\(file.url.lastPathComponent)”: \(UserMessages.unpreservedStreams(file.streams))")
        }
        return [
            String(
                localized:
                    "MacEase can’t keep these streams in an edited file, so the file you save won’t include them:"),
            lines.joined(separator: "\n"),
            purpose == .open
                ? String(localized: "Opening doesn’t change the originals.")
                : String(localized: "Adding doesn’t change the originals."),
        ].joined(separator: "\n\n")
    }

    var actionTitle: String {
        let names = UserMessages.unpreservedStreams(streams, titleCase: true)
        return purpose == .open
            ? String(localized: "Open Without \(names)", comment: "Opens media, dropping the named streams")
            : String(localized: "Add Without \(names)", comment: "Adds media, dropping the named streams")
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
