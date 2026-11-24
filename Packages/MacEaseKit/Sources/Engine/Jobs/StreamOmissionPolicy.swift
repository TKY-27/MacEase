import Foundation

extension Settings.UnpreservedStreamsChoice {
    var permitsAutomaticOmission: Bool { self == .omitFromNewFiles }
}

extension WorkItem {
    func savesNewFile(context: ItemContext) async throws -> Bool {
        if newFileNaming != nil || derivesOutput { return true }
        guard let omissionOptions else { return false }
        if NewFileNaming(options: omissionOptions) == nil {
            switch omissionOptions {
            case .video, .audio: return true
            default: return false
            }
        }
        guard case .video(.edit(let edit)) = omissionOptions, let source = inputs.first else { return false }
        if let sources = edit.sources, sources.count > 1 { return true }
        let input = try await MediaInput.open(source)
        guard let video = input.video else { return false }
        let plan = try VideoEdits.plan(
            .edit(edit), input: input, source: video, settings: context.settings.video,
            audioSettings: context.settings.audio)
        return try await VideoProperties.prepare(plan, input: input, context: context).derived
    }
}
