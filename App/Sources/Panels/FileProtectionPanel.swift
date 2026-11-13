import Engine
import Observation
import SwiftUI

@MainActor
@Observable
final class FileProtectionModel {
    let source: URL
    var decrypt: Bool
    var password = ""
    var confirmation = ""
    private(set) var failure: String?
    private let run: @MainActor (Batch) -> Void

    init(source: URL, run: @escaping @MainActor (Batch) -> Void) {
        self.source = source
        self.run = run
        decrypt = source.pathExtension.lowercased() == "age"
    }

    var canRun: Bool {
        !password.isEmpty && password.utf8.count <= 4_096
            && (decrypt || (password.count >= 12 && password == confirmation))
    }

    func submit() {
        guard canRun else { return }
        failure = nil
        do {
            let batch = try FileProtection().batch(source: source, password: password, decrypt: decrypt)
            password = ""
            confirmation = ""
            run(batch)
        } catch {
            failure = error.localizedDescription
        }
    }

    func close() {
        password = ""
        confirmation = ""
    }
}

struct FileProtectionPanel: View {
    @Bindable var model: FileProtectionModel
    let close: () -> Void

    var body: some View {
        PanelForm(
            actionTitle: model.decrypt ? String(localized: "Decrypt") : String(localized: "Encrypt"),
            canRun: model.canRun, cancel: close
        ) {
            model.submit()
            if model.failure == nil { close() }
        } content: {
            Section {
                Text(model.source.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } header: {
                Text("File")
            }
            Section {
                Picker("Action", selection: $model.decrypt) {
                    Text("Encrypt").tag(false)
                    Text("Decrypt").tag(true)
                }
                .pickerStyle(.segmented)
                SecureField("Password", text: $model.password)
                if !model.decrypt {
                    SecureField("Confirm password", text: $model.confirmation)
                }
            }
            Section {
                Text("Use at least 12 characters for a new password. A forgotten password cannot be recovered.")
                    .foregroundStyle(.secondary)
                Text("The original file will be kept.")
                    .foregroundStyle(.secondary)
                if let failure = model.failure {
                    Text(failure).foregroundStyle(.red)
                }
            }
        }
        .onDisappear { model.close() }
    }
}
