import CoreGraphics
import CoreText
import Foundation
import Vision

enum TextRecognition {
    private enum Probe {
        static let text = "MacEase"
        static let canvas = CGSize(width: 400, height: 120)
        static let fontSize: CGFloat = 64
        static let baseline = CGPoint(x: 20, y: 30)
    }

    /// Virtual Macs may lack the recognition models.
    static var isAvailable: Bool {
        get async {
            let size = Probe.canvas
            guard
                let context = CGContext(
                    data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(origin: .zero, size: size))
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: Probe.text,
                    attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, Probe.fontSize, nil)]))
            context.textPosition = Probe.baseline
            CTLineDraw(line, context)
            guard let image = context.makeImage() else { return false }
            return (try? await text(in: image, languages: [])).map { $0.contains(Probe.text) } ?? false
        }
    }

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
