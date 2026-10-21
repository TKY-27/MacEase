import AVFoundation
import Formats
import Foundation
import ImageIO
import PDFKit

enum OutputVerifier {
    static func verify(_ file: StagedFile) async throws {
        let values = try file.url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values.isDirectory == true {
            guard case .folder = file.check else { throw EngineError.encodeFailed("unexpected directory") }
            let contents = try FileManager.default.contentsOfDirectory(atPath: file.url.path)
            guard !contents.isEmpty else { throw EngineError.encodeFailed("empty output folder") }
            return
        }
        guard (values.fileSize ?? 0) > 0 else { throw EngineError.encodeFailed("empty output") }
        switch file.check {
        case .image:
            guard let source = CGImageSourceCreateWithURL(file.url as CFURL, nil), CGImageSourceGetCount(source) > 0
            else { throw EngineError.encodeFailed("output image does not decode") }
            var budget = FrameMemoryBudget()
            try budget.reserve(source: source, index: 0)
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw EngineError.encodeFailed("output image does not decode")
            }
            var actualBudget = FrameMemoryBudget()
            try actualBudget.reserve(image)
        case .sdrImage:
            try ImageSDR.verify(file.url)
        case .media:
            try await verifyMedia(file.url)
        case .sdrVideo:
            try await verifyMedia(file.url)
            try await VideoSDR.verify(file.url)
        case .audio:
            try verifyAudio(file.url)
        case .pdf:
            guard let document = PDFDocument(url: file.url), document.pageCount > 0 else {
                throw EngineError.encodeFailed("output PDF does not open")
            }
        case .plist:
            _ = try PropertyListSerialization.propertyList(from: Data(contentsOf: file.url), options: [], format: nil)
        case .text(let encoding):
            guard String(data: try Data(contentsOf: file.url, options: .mappedIfSafe), encoding: encoding) != nil else {
                throw EngineError.encodeFailed("output text is not valid in its encoding")
            }
        case .svg:
            let parser = XMLParser(contentsOf: file.url)
            parser?.shouldResolveExternalEntities = false
            guard parser?.parse() == true else { throw EngineError.encodeFailed("output SVG is not valid XML") }
        case .archive:
            do {
                try ArchiveListing.verify(file.url)
            } catch {
                throw EngineError.encodeFailed("output archive does not list: \(error)")
            }
        case .folder:
            throw EngineError.encodeFailed("expected a folder")
        case .decompressed:
            return
        }
    }

    /// Covers Ogg, which AVFoundation may not open.
    private static func verifyAudio(_ url: URL) throws {
        var frames = 0
        do {
            let source = try AudioInput(url: url).open()
            while let chunk = try source.read() {
                try Task.checkCancellation()
                frames += chunk.count
            }
        } catch is CancellationError {
            throw EngineError.cancelled
        } catch {
            throw EngineError.encodeFailed("output audio does not decode: \(error)")
        }
        guard frames > 0 else { throw EngineError.encodeFailed("output audio is empty") }
    }

    private static func verifyMedia(_ url: URL) async throws {
        if let demuxer = try ContainerSignature.demuxer(for: url) {
            try verifyPackets(demuxer)
            return
        }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.load(.tracks)
        var playable = false
        for track in tracks where try await track.load(.isPlayable) {
            playable = true
        }
        guard playable else { throw EngineError.encodeFailed("output has no playable track") }
    }

    /// Every track needs a parsed packet.
    private static func verifyPackets(_ demuxer: any MediaDemuxer) throws {
        var demuxer = demuxer
        var seen = Set<Int>()
        while let packet = try demuxer.nextPacket() { seen.insert(packet.track) }
        guard Set(demuxer.tracks.map(\.number)).isSubset(of: seen) else {
            throw EngineError.encodeFailed("output has a track without packets")
        }
    }
}
