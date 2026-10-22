import Engine
import MenuCatalog
import SwiftUI
import os

struct TargetSizeChoice: Codable, Equatable {
    var megabytes: Double? = 10
}

struct TargetSizePanel: View {
    let op: OperationID
    let inputs: [URL]
    let settings: Engine.Settings
    @State var choice: TargetSizeChoice
    let cancel: () -> Void
    let run: (TargetSizeChoice, OperationOptions) -> Void

    @State private var largestFile: Int64?
    @FocusState private var sizeFocused: Bool

    private static let bytesPerMegabyte = 1_000_000.0
    private static let fieldWidth: CGFloat = 96

    var body: some View {
        PanelForm(
            actionTitle: String(localized: "Compress", comment: "Target size panel action"), canRun: options != nil,
            cancel: cancel
        ) {
            if let options { run(choice, options) }
        } content: {
            Section {
                LabeledContent {
                    HStack(spacing: PanelLayout.unitSpacing) {
                        TextField(
                            "Target size", value: $choice.megabytes,
                            format: .number.precision(.fractionLength(0...2)), prompt: Text(verbatim: "8")
                        )
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: Self.fieldWidth)
                        .focused($sizeFocused)
                        Text(verbatim: "MB")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                } label: {
                    Text("Target size")
                    if let largestFile {
                        Text("Largest selected file: \(largestFile.fileSize)", comment: "Target size panel hint")
                    }
                }
            } footer: {
                if let bytes {
                    Text("\(bytes, format: .number) bytes", comment: "Target size panel byte echo")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    ProblemLabel(
                        text: String(
                            localized: "Enter a size such as 8 MB.", comment: "Target size panel validation"))
                }
            }
        }
        .onAppear { sizeFocused = true }
        .task { largestFile = await Self.largestSize(of: inputs) }
    }

    /// Decimal megabytes, as the SPEC requires.
    private var bytes: Int64? {
        guard let megabytes = choice.megabytes, megabytes.isFinite, megabytes > 0 else { return nil }
        return Int64(exactly: (megabytes * Self.bytesPerMegabyte).rounded(.down)).flatMap { $0 > 0 ? $0 : nil }
    }

    private var options: OperationOptions? {
        guard let bytes else { return nil }
        let video = settings.video
        switch op {
        case .imageCompress:
            return .image(
                .compress(
                    ImageCompression(
                        goal: .bytes(bytes), allowsDownscale: video.allowDownscale,
                        allowsFrameRateReduction: video.allowFrameRateReduction,
                        stripsGPS: !settings.image.keepGPSOnPlatformPresets)))
        case .videoCompress:
            return .video(
                .compress(
                    VideoCompression(
                        goal: .bytes(bytes), allowsDownscale: video.allowDownscale,
                        allowsFrameRateReduction: video.allowFrameRateReduction)))
        case .audioCompress:
            return .audio(.compress(.targetBytes(bytes)))
        default:
            return nil
        }
    }

    private static func largestSize(of urls: [URL]) async -> Int64? {
        do {
            return try await offMain {
                try urls.compactMap { try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.max().map(Int64.init)
            }
        } catch {
            let failure = error as NSError
            Logger(category: "panels").error(
                "No file sizes for hint (\(failure.domain, privacy: .public) \(failure.code, privacy: .public)): \(failure.localizedDescription, privacy: .private)"
            )
            return nil
        }
    }
}
