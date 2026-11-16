import AVFoundation
import Engine
import Foundation
import ImageIO

struct PreviewFact: Hashable, Sendable {
    let label: String
    let value: String
}

struct PreviewFileDetails: Sendable {
    let kind: PreviewKind
    let isFolder: Bool
    let subtitle: String
    let aspectRatio: CGFloat?
    let facts: [PreviewFact]
    private static let entryLimit = 100_000
    private static let timeLimit: TimeInterval = 2
    private static let rotatedOrientations: ClosedRange<Int> = 5...8

    static func read(_ url: URL) async throws -> Self {
        let attributes = try url.resourceValues(forKeys: [
            .isDirectoryKey, .isRegularFileKey, .isPackageKey, .contentTypeKey, .localizedTypeDescriptionKey,
            .fileSizeKey, .creationDateKey, .contentModificationDateKey,
        ])
        let typeName = attributes.localizedTypeDescription ?? url.pathExtension.uppercased()
        var dates: [PreviewFact] = []
        if let created = attributes.creationDate {
            dates.append(PreviewFact(label: String(localized: "Created"), value: created.formatted(dateStyle)))
        }
        if let modified = attributes.contentModificationDate {
            dates.append(
                PreviewFact(
                    label: String(localized: "preview.fact.modified", defaultValue: "Modified"),
                    value: modified.formatted(dateStyle)))
        }
        if attributes.isDirectory == true {
            if attributes.isPackage == true {
                return Self(kind: .quickLook, isFolder: false, subtitle: typeName, aspectRatio: nil, facts: dates)
            }
            let (count, bytes) = try folderTotals(url)
            let items = PreviewFact(
                label: String(localized: "preview.fact.items", defaultValue: "Items"),
                value: String(localized: "\(count) items"))
            return Self(
                kind: .quickLook, isFolder: true, subtitle: "\(typeName) · \(bytes.fileSize)", aspectRatio: nil,
                facts: [items] + dates)
        }
        guard attributes.isRegularFile == true, let size = attributes.fileSize else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let kind = PreviewKind.resolve(type: attributes.contentType, extension: url.pathExtension)
        var aspectRatio: CGFloat?
        var facts: [PreviewFact]
        do {
            (aspectRatio, facts) = try await typeFacts(url, kind: kind)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Viewers and actions still work without these facts.
            facts = [PreviewFact(label: String(localized: "Details"), value: String(localized: "Unavailable"))]
        }
        return Self(
            kind: kind, isFolder: false, subtitle: "\(typeName) · \(Int64(size).fileSize)", aspectRatio: aspectRatio,
            facts: facts + dates)
    }

    private static var dateStyle: Date.FormatStyle { Date.FormatStyle(date: .numeric, time: .shortened) }

    private static func typeFacts(_ url: URL, kind: PreviewKind) async throws -> (CGFloat?, [PreviewFact]) {
        switch kind {
        case .image: return try imageFacts(url)
        case .media, .audio: return try await mediaFacts(url)
        case .pdf:
            guard let document = CGPDFDocument(url as CFURL) else { throw CocoaError(.fileReadCorruptFile) }
            let pages = PreviewFact(
                label: String(localized: "preview.fact.pages", defaultValue: "Pages"),
                value: document.numberOfPages.formatted())
            return (nil, [pages])
        case .text, .html, .markdown, .json, .propertyList, .quickLook: return (nil, [])
        }
    }

    private static func imageFacts(_ url: URL) throws -> (CGFloat?, [PreviewFact]) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0
        else { throw CocoaError(.fileReadCorruptFile) }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let rotated = rotatedOrientations.contains(orientation)
        let (shownWidth, shownHeight) = rotated ? (height, width) : (width, height)
        let signal = try ImageSDR.content(source, index: 0)
        var facts = [dimensions(shownWidth, shownHeight)]
        if let profile = properties[kCGImagePropertyProfileName] as? String {
            facts.append(
                PreviewFact(
                    label: String(localized: "preview.fact.colorProfile", defaultValue: "Color Profile"),
                    value: profile))
        }
        facts.append(
            PreviewFact(
                label: String(localized: "preview.fact.dynamicRange", defaultValue: "Dynamic Range"),
                value: signal.gainMap || signal.pixels ? "HDR" : "SDR"))
        return (CGFloat(shownWidth) / CGFloat(shownHeight), facts)
    }

    private static func mediaFacts(_ url: URL) async throws -> (CGFloat?, [PreviewFact]) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        var facts: [PreviewFact] = []
        var aspectRatio: CGFloat?
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
            let shown = natural.applying(transform)
            let width = Int(abs(shown.width).rounded())
            let height = Int(abs(shown.height).rounded())
            if width > 0, height > 0 {
                facts.append(dimensions(width, height))
                aspectRatio = CGFloat(width) / CGFloat(height)
            }
        }
        if duration.isFinite {
            let pattern: Duration.TimeFormatStyle.Pattern = duration >= 3600 ? .hourMinuteSecond : .minuteSecond
            facts.insert(
                PreviewFact(
                    label: String(localized: "Duration"),
                    value: Duration.seconds(duration).formatted(.time(pattern: pattern))), at: 0)
        }
        return (aspectRatio, facts)
    }

    private static func dimensions(_ width: Int, _ height: Int) -> PreviewFact {
        PreviewFact(
            label: String(localized: "preview.fact.dimensions", defaultValue: "Dimensions"),
            value: "\(width) × \(height)")
    }

    private static func folderTotals(_ url: URL) throws -> (Int, Int64) {
        var enumerationFailure: Error?
        guard
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                errorHandler: { _, error in
                    enumerationFailure = error; return false
                })
        else { throw CocoaError(.fileReadUnknown) }
        let deadline = Date().addingTimeInterval(timeLimit)
        var count = 0
        var scanned = 0
        var bytes: Int64 = 0
        while let child = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            scanned += 1
            guard scanned <= entryLimit, Date() < deadline else { throw CocoaError(.fileReadTooLarge) }
            if enumerator.level == 1 { count += 1 }
            let values = try child.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true, let size = values.fileSize { bytes += Int64(size) }
        }
        if let enumerationFailure { throw enumerationFailure }
        return (count, bytes)
    }
}
