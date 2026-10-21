import AppKit
import Engine
import SwiftUI
import os

struct TextResultPanel: View {
    let text: String
    let close: () -> Void
    let save: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(text)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .frame(height: PanelLayout.listHeight)
            PanelBar(
                actionTitle: String(localized: "Copy", comment: "Text result action"),
                cancelTitle: String(localized: "Done", comment: "Panel button"), cancel: close
            ) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } accessory: {
                Button("Save…", action: save)
            }
        }
        .frame(width: PanelLayout.wideWidth)
    }
}

/// The password is never persisted.
struct PasswordPanel: View {
    let archives: [URL]
    let wasWrong: Bool
    let cancel: () -> Void
    let run: (_ password: String, _ forAll: Bool) -> Void

    @State private var password = ""
    @State private var forAll = true

    var body: some View {
        PanelForm(
            actionTitle: String(localized: "Extract", comment: "Password panel action"), canRun: !password.isEmpty,
            cancel: cancel
        ) {
            run(password, forAll)
        } content: {
            Text(
                wasWrong
                    ? String(localized: "The password for “\(archives[0].lastPathComponent)” was wrong. Try again.")
                    : String(localized: "“\(archives[0].lastPathComponent)” is protected by a password.")
            )
            .fixedSize(horizontal: false, vertical: true)
            SecureField("Password", text: $password)
            if archives.count > 1 {
                Toggle("Use for all \(archives.count) archives in this batch", isOn: $forAll)
            }
        }
    }
}

struct EncodingPanel: View {
    let file: URL
    @State var encoding: SourceTextEncoding
    let cancel: () -> Void
    let run: (SourceTextEncoding) -> Void

    @State private var sample: Data?
    @State private var previewFailure: String?

    nonisolated private static let sampleBytes = 600

    var body: some View {
        PanelForm(
            actionTitle: String(localized: "Convert", comment: "Encoding panel action"), cancel: cancel
        ) {
            run(encoding)
        } content: {
            Text(
                "MacEase could not tell how “\(file.lastPathComponent)” is encoded. Choose the encoding that shows the text correctly."
            )
            .fixedSize(horizontal: false, vertical: true)
            Picker("Encoding", selection: $encoding) {
                ForEach(SourceTextEncoding.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text(preview)
                .font(.body.monospaced())
                .lineLimit(Self.previewLines)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(Text("Preview"))
        }
        .task {
            let file = file
            do {
                sample = try await offMain {
                    try OperationPlanner.validateInput(file)
                    let sampleReader = try FileHandle(forReadingFrom: file)
                    defer {
                        do {
                            try sampleReader.close()
                        } catch {
                            let failure = error as NSError
                            Logger(category: "panels").error(
                                "Preview close failed (\(failure.domain, privacy: .public) \(failure.code, privacy: .public)): \(failure.localizedDescription, privacy: .private)"
                            )
                        }
                    }
                    return try sampleReader.read(upToCount: Self.sampleBytes)
                }
            } catch {
                let failure = error as NSError
                Logger(category: "panels").error(
                    "Encoding preview unreadable (\(failure.domain, privacy: .public) \(failure.code, privacy: .public)): \(failure.localizedDescription, privacy: .private)"
                )
                previewFailure = UserMessages.describe(
                    EngineError.wrapping(error, path: file.path), file: file.lastPathComponent)
            }
        }
    }

    private static let previewLines = 6

    private var preview: String {
        if let previewFailure { return previewFailure }
        guard let sample else { return "" }
        return String(data: sample, encoding: encoding.foundationEncoding)
            ?? String(
                localized: "This encoding does not fit the file.", comment: "Encoding panel preview")
    }
}

extension SourceTextEncoding {
    var title: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf16LittleEndian: "UTF-16 LE"
        case .utf16BigEndian: "UTF-16 BE"
        case .cp932: String(localized: "Japanese (Shift_JIS)", comment: "Text encoding")
        case .eucJP: String(localized: "Japanese (EUC-JP)", comment: "Text encoding")
        }
    }

    fileprivate var foundationEncoding: String.Encoding {
        switch self {
        case .utf8: .utf8
        case .utf16LittleEndian: .utf16LittleEndian
        case .utf16BigEndian: .utf16BigEndian
        case .cp932:
            String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))
        case .eucJP: .japaneseEUC
        }
    }
}
