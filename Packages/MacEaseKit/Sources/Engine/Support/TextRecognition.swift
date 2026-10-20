import CoreGraphics
import Foundation
import Vision

enum TextRecognition {
    /// Empty `languages` lets Vision detect them.
    static func text(in image: CGImage, languages: [String]) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = languages.isEmpty
        if !languages.isEmpty { request.recognitionLanguages = languages.map(Locale.Language.init(identifier:)) }
        let observations = try await request.perform(on: image)
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
