import CoreImage.CIFilterBuiltins
import Engine
import Observation
import SwiftUI

@MainActor @Observable
final class FileShareModel {
    private struct QRFailure: LocalizedError {
        var errorDescription: String? { String(localized: "The QR code could not be created.") }
    }

    let inputs: [URL]
    var interfaces: [LocalShareInterface]
    var selectedInterface: LocalShareInterface?
    private(set) var session: LocalFileShare?
    private(set) var address: URL?
    private(set) var qrImage: NSImage?
    private(set) var error: String?
    private(set) var isStarting = false
    private var generation = UUID()

    init(inputs: [URL]) {
        self.inputs = inputs
        interfaces = LocalFileShare.availableInterfaces()
        selectedInterface = interfaces.first
    }

    func refreshInterfaces() {
        interfaces = LocalFileShare.availableInterfaces()
        if !interfaces.contains(where: { $0 == selectedInterface }) { selectedInterface = interfaces.first }
    }

    func start() async {
        guard !isStarting, session == nil, let selectedInterface else { return }
        isStarting = true
        error = nil
        generation = UUID()
        let expected = generation
        do {
            let share = try LocalFileShare(files: inputs, on: selectedInterface) { [weak self] in
                Task { @MainActor in
                    guard self?.generation == expected else { return }
                    self?.session = nil
                    self?.address = nil
                    self?.qrImage = nil
                }
            }
            session = share
            let url = try await share.start()
            guard generation == expected, session === share else { share.stop(); return }
            guard let image = Self.makeQR(url) else { throw QRFailure() }
            address = url
            qrImage = image
        } catch {
            guard generation == expected else { return }
            session?.stop()
            session = nil
            address = nil
            qrImage = nil
            self.error = error.localizedDescription
        }
        isStarting = false
    }

    func stop() {
        generation = UUID()
        session?.stop()
        isStarting = false
        session = nil
        address = nil
        qrImage = nil
    }

    private static func makeQR(_ url: URL) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage,
            let cgImage = CIContext().createCGImage(image, from: image.extent)
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

struct FileSharePanel: View {
    @Bindable var model: FileShareModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Selected files") {
                    ForEach(model.inputs, id: \.self) { url in
                        Text(url.lastPathComponent).lineLimit(1)
                    }
                }
                if let address = model.address, let session = model.session {
                    Section("Share on this network") {
                        if let qrImage = model.qrImage {
                            Image(nsImage: qrImage)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 220, height: 220)
                                .padding(16)
                                .background(.white)
                                .accessibilityLabel("QR code for shared files")
                        }
                        Text(address.absoluteString)
                            .textSelection(.enabled)
                            .font(.system(.caption, design: .monospaced))
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("Expires in \(max(0, Int(session.expiresAt.timeIntervalSince(context.date)))) seconds")
                                .monospacedDigit()
                        }
                    }
                } else {
                    Section("Network") {
                        Picker("Interface", selection: $model.selectedInterface) {
                            ForEach(model.interfaces) { networkInterface in
                                Text("\(networkInterface.kind) — \(networkInterface.address)")
                                    .tag(Optional(networkInterface))
                            }
                        }
                        Button("Refresh Networks") { model.refreshInterfaces() }
                        if model.interfaces.isEmpty {
                            Text("Connect to a private Wi-Fi or Ethernet network to share files.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Text(
                        "Use the same trusted network. HTTP is not encrypted. Files stay on this Mac; no cloud service or internet port forwarding is used."
                    )
                    .foregroundStyle(.secondary)
                    if let error = model.error { ProblemLabel(text: error) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Close") {
                    model.stop(); close()
                }
                .keyboardShortcut(.cancelAction)
                if model.session != nil {
                    Button("Stop Sharing") { model.stop() }
                } else {
                    Button("Start Sharing") { Task { await model.start() } }
                        .disabled(
                            model.selectedInterface == nil || model.isStarting || model.inputs.isEmpty
                                || model.inputs.count > LocalFileShare.maximumFiles
                        )
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
        }
        .frame(width: PanelLayout.width)
        .onDisappear { model.stop() }
    }
}
