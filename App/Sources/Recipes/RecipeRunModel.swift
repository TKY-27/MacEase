import Engine
import Foundation
import Observation

@MainActor @Observable final class RecipeRunModel {
    private(set) var busy = false
    var failure: String?
    var streamConsent: StreamConsentRequest?
    private var recipe: Recipe?
    private var destination: URL?
    private var omissions: [URL: StreamOmission] = [:]
    private let inputs: [URL]
    private let settings: Engine.Settings
    private let onRun: (Batch) async -> BatchOutcome?
    private let onComplete: () -> Void

    init(
        inputs: [URL], settings: Engine.Settings,
        onRun: @escaping (Batch) async -> BatchOutcome?, onComplete: @escaping () -> Void
    ) {
        self.inputs = inputs
        self.settings = settings
        self.onRun = onRun
        self.onComplete = onComplete
    }

    func run(_ recipe: Recipe, destination: URL?) async {
        guard !busy else { return }
        self.recipe = recipe
        self.destination = destination
        omissions = [:]
        busy = true
        failure = nil
        defer { busy = false }
        do {
            try RecipePlanner.validate(recipe: recipe, inputs: inputs)
            let required = try await RecipePlanner.streamOmissions(
                recipe: recipe, inputs: inputs, unpreservedStreams: settings.unpreservedStreams)
            if required.isEmpty {
                try await submit(recipe)
            } else {
                requestConsent(required)
            }
        } catch { showFailure(error) }
    }

    func continueWithoutStreams(_ request: StreamConsentRequest) async {
        guard !busy, let recipe else { return }
        busy = true
        failure = nil
        streamConsent = nil
        defer { busy = false }
        do {
            try approve(request.files)
            try await submit(recipe)
        } catch { showFailure(error) }
    }

    private func approve(_ files: [StreamConsentRequest.File]) throws {
        for file in files {
            try file.omission.stamp.validate(
                file.url, message: String(localized: "“\(file.name)” changed after it was checked"))
            let previous = omissions[file.url]?.streams(covering: file.omission.stamp) ?? []
            omissions[file.url] = StreamOmission(
                stamp: file.omission.stamp, streams: previous.union(file.omission.streams))
        }
    }

    private func submit(_ recipe: Recipe) async throws {
        let batch = try RecipePlanner.batch(
            recipe: recipe, inputs: inputs, destination: destination, settings: settings, omissions: omissions,
            unpreservedStreams: settings.unpreservedStreams)
        guard let outcome = await onRun(batch) else { return }
        let refused = Set(
            outcome.outcomes.flatMap { result -> [UnpreservedStream] in
                if case .failed(.invalidInput(.unpreservedStreams(let streams))) = result { return streams }
                return []
            })
        if !refused.isEmpty {
            let stamps = try Dictionary(
                uniqueKeysWithValues: Set(inputs).map { source in
                    guard let stamp = outcome.details.first?.inputStamps[source] else {
                        throw ActivityAvailability.unavailable
                    }
                    return (source, stamp)
                })
            for (source, stamp) in stamps { try ActivitySession.validate(source, stamp: stamp) }
            let required = try await RecipePlanner.streamOmissions(recipe: recipe, inputs: inputs, unavailable: refused)
            for (source, stamp) in stamps { try ActivitySession.validate(source, stamp: stamp) }
            var additional: [URL: StreamOmission] = [:]
            for (source, omission) in required {
                let unapproved = omission.streams.subtracting(
                    omissions[source]?.streams(covering: omission.stamp) ?? [])
                if !unapproved.isEmpty {
                    additional[source] = StreamOmission(stamp: omission.stamp, streams: unapproved)
                }
            }
            if !additional.isEmpty {
                requestConsent(additional)
                return
            }
        }
        if let problem = outcome.outcomes.compactMap({ result -> EngineError? in
            if case .failed(let error) = result { return error }
            return nil
        }).first {
            showFailure(problem)
        } else {
            onComplete()
        }
    }

    private func showFailure(_ error: Error) {
        let problem = EngineError.wrapping(error, path: "")
        failure = [UserMessages.describe(problem, file: recipe?.name ?? ""), UserMessages.technicalDetail(problem)]
            .compactMap { $0 }.joined(separator: "\n")
    }

    private func requestConsent(_ required: [URL: StreamOmission]) {
        streamConsent = StreamConsentRequest(
            purpose: .proceed,
            files: required.map { .init(url: $0.key, omission: $0.value) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }
}
