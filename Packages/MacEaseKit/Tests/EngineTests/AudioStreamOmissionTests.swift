import Foundation
import MenuCatalog
import Testing

@testable import Engine
@testable import Formats

@Suite struct AudioStreamOmissionTests {
    @Test(arguments: ["GEOB", "SYLT", "PRIV", "APIC"])
    func consentedID3ContentDoesNotRefuseReplacement(frameID: String) async throws {
        let source = try await id3Source(frameID: frameID)
        let expected = kind(for: frameID)
        let original = try Data(contentsOf: source)
        for consent: Set<UnpreservedStream> in [[], [.timecode]] {
            let refused = try await convert([source], omitting: consent, mode: .replace)
            #expect(refused.outcomes == [.failed(.invalidInput(.unpreservedStreams([expected])))])
            #expect(refused.record == nil)
            #expect(try Data(contentsOf: source) == original)
            #expect(
                try FileManager.default.contentsOfDirectory(atPath: source.deletingLastPathComponent().path) == [
                    source.lastPathComponent
                ])
        }
        if frameID != "APIC" {
            #expect(try await AudioMetadataLoss.hasUnsupportedTags(source))
            #expect(try await !AudioMetadataLoss.hasUnsupportedTags(source, omitting: [expected]))
        }
        let outcome = try await convert([source], omitting: [expected], mode: .replace)
        guard case .succeeded(let outputs, let warnings) = outcome.outcomes.first else {
            Issue.record("expected consented replacement: \(outcome.outcomes)")
            return
        }
        #expect(warnings == [.streamsOmitted([expected])])
        let output = try #require(outputs.first)
        #expect(try !AudioSignals.decode(output).samples.isEmpty)
        let tags = try await AudioInput(url: output).tags()
        #expect(tags.title == "Kept title")
        if frameID == "APIC" { #expect(tags.artwork == AudioSignals.pngArtwork()) }
    }

    @Test func contentConsentDoesNotApproveUnrelatedTags() async throws {
        let source = try await id3Source(frameID: "GEOB", includesGenre: true)
        let original = try Data(contentsOf: source)
        let outcome = try await convert([source], omitting: [.attachment], mode: .replace)
        #expect(outcome.outcomes == [.failed(.audioMetadataUnsupported)])
        #expect(try Data(contentsOf: source) == original)
        #expect(outcome.record == nil)
    }

    @Test(arguments: [Settings.OutputMode.replace, .newFile])
    func mixedBatchReportsOnlyActualOmissions(mode: Settings.OutputMode) async throws {
        let marked = try await id3Source(frameID: "PRIV")
        let folder = marked.deletingLastPathComponent()
        let clean = folder.appending(path: "clean.mp3")
        try await AudioSignals.write(AudioSignals.music(seconds: 0.2), to: clean, format: .mp3)
        let beforeMarked = try Data(contentsOf: marked)
        let beforeClean = try Data(contentsOf: clean)
        let outcome = try await convert([marked, clean], omitting: [.data], mode: mode)
        try #require(outcome.outcomes.count == 2)
        for (index, result) in outcome.outcomes.enumerated() {
            guard case .succeeded(let outputs, let warnings) = result else {
                Issue.record("expected batch conversion: \(result)")
                continue
            }
            #expect(warnings == (index == 0 ? [.streamsOmitted([.data])] : []))
            #expect(try !AudioSignals.decode(try #require(outputs.first)).samples.isEmpty)
        }
        if mode == .newFile {
            #expect(try Data(contentsOf: marked) == beforeMarked)
            #expect(try Data(contentsOf: clean) == beforeClean)
        }
    }

    @Test(arguments: [Settings.OutputMode.replace, .newFile])
    func flacExtraContentRequiresEachKindBeforeWriting(mode: Settings.OutputMode) async throws {
        let source = try await flacSource()
        let original = try Data(contentsOf: source)
        let folder = source.deletingLastPathComponent()
        for consent: Set<UnpreservedStream> in [
            [], [.chapter], [.chapter, .attachment], [.chapter, .attachment, .data],
        ] {
            let outcome = try await convert([source], omitting: consent, mode: mode)
            let missing: [UnpreservedStream] = [.chapter, .attachment, .data].filter { !consent.contains($0) }
            if !missing.isEmpty {
                #expect(outcome.outcomes == [.failed(.invalidInput(.unpreservedStreams(missing)))])
                #expect(outcome.record == nil)
                #expect(try Data(contentsOf: source) == original)
                #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [source.lastPathComponent])
            } else {
                guard case .succeeded(let outputs, let warnings) = outcome.outcomes.first else {
                    Issue.record("expected consented FLAC conversion: \(outcome.outcomes)")
                    return
                }
                #expect(warnings == [.streamsOmitted([.chapter, .attachment, .data])])
                let output = try #require(outputs.first)
                #expect(try !AudioSignals.decode(output).samples.isEmpty)
                let tags = try await AudioInput(url: output).tags()
                #expect(tags.title == "Kept title")
                #expect(tags.artwork == AudioSignals.pngArtwork())
                if mode == .newFile { #expect(try Data(contentsOf: source) == original) }
            }
        }
    }

    private func kind(for frameID: String) -> UnpreservedStream {
        switch frameID {
        case "SYLT": .subtitle
        case "PRIV": .data
        default: .attachment
        }
    }

    func id3Source(frameID: String, includesGenre: Bool = false) async throws -> URL {
        let folder = try TestVolume.makeFolder()
        let source = folder.appending(path: "marked.mp3")
        let tags = AudioTags(title: "Kept title", artwork: frameID == "APIC" ? AudioSignals.pngArtwork() : nil)
        try await AudioSignals.write(AudioSignals.music(seconds: 0.2), to: source, format: .mp3, tags: tags)
        let encoded = try Data(contentsOf: source)
        let tagLength = try #require(ID3Tag.length(prefix: Array(encoded.prefix(ID3Tag.headerLength))))
        var frames = frame("TIT2", payload: Data([3]) + Data("Kept title".utf8))
        if frameID == "APIC" {
            frames.append(
                frame(
                    "APIC",
                    payload: Data([0]) + Data("image/png\0".utf8) + Data([3, 0]) + AudioSignals.pngArtwork().data))
        }
        let payload: Data
        switch frameID {
        case "CHAP":
            payload =
                Data("chapter1\0".utf8) + Data(repeating: 0, count: 4)
                + Data([0, 0, 3, 232]) + Data(repeating: 0xFF, count: 8)
        case "GEOB": payload = Data([0]) + Data("application/octet-stream\0file\0object\0payload".utf8)
        case "SYLT":
            payload = Data([0]) + Data("eng".utf8) + Data([2, 1, 0]) + Data("words\0".utf8) + Data([0, 0, 0, 0])
        case "PRIV": payload = Data("org.macease.test\0payload".utf8)
        case "APIC": payload = Data([0]) + Data("image/png\0".utf8) + Data([4, 0]) + AudioSignals.pngArtwork().data
        default: throw EngineError.invalidInput(.malformed("unknown test frame"))
        }
        frames.append(frame(frameID, payload: payload))
        if includesGenre { frames.append(frame("TCON", payload: Data([0]) + Data("Jazz".utf8))) }
        let length = UInt32(frames.count)
        let size = Data((0..<4).reversed().map { UInt8(length >> ($0 * 7) & 0x7F) })
        let tagged = Data("ID3".utf8) + Data([4, 0, 0]) + size + frames + encoded.dropFirst(tagLength)
        try tagged.write(to: source)
        return source
    }

    private func frame(_ identifier: String, payload: Data) -> Data {
        let length = UInt32(payload.count)
        return Data(identifier.utf8) + Data((0..<4).reversed().map { UInt8(length >> ($0 * 7) & 0x7F) })
            + Data([0, 0]) + payload
    }

    func flacSource() async throws -> URL {
        let folder = try TestVolume.makeFolder()
        let source = folder.appending(path: "marked.flac")
        try await AudioSignals.write(
            AudioSignals.music(seconds: 0.2), to: source, format: .flac,
            tags: AudioTags(title: "Kept title", artwork: AudioSignals.pngArtwork()))
        let encoded = try Data(contentsOf: source)
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        let metadata = try FLACBlock.read(reader)
        var blocks = metadata.blocks
        blocks.append(FLACBlock.Block(type: FLACBlock.picture, body: FLACPicture.encode(AudioSignals.pngArtwork())))
        var cueSheet = Data(repeating: 0, count: 480)
        cueSheet[395] = 2
        cueSheet[404] = 1
        cueSheet[431] = 1
        cueSheet[440] = 1
        let leadOut: UInt64 = 8_820
        for offset in 0..<8 { cueSheet[444 + offset] = UInt8(leadOut >> ((7 - offset) * 8) & 0xFF) }
        cueSheet[452] = 255
        blocks.append(FLACBlock.Block(type: FLACBlock.cueSheet, body: cueSheet))
        blocks.append(FLACBlock.Block(type: 2, body: Data("testpayload".utf8)))
        var marked = FLACBlock.marker
        for (index, block) in blocks.enumerated() {
            marked.append(FLACBlock.header(type: block.type, length: block.body.count, last: index == blocks.count - 1))
            marked.append(block.body)
        }
        marked.append(encoded.dropFirst(Int(metadata.framesOffset)))
        try marked.write(to: source)
        return source
    }

    private func convert(_ sources: [URL], omitting consent: Set<UnpreservedStream>, mode: Settings.OutputMode)
        async throws -> BatchOutcome
    {
        var settings = Settings()
        settings.outputMode = mode
        let support = try TestVolume.makeFolder().appending(path: "support")
        let engine = try JobEngine(supportDirectory: support, concurrency: 1)
        let request = OperationRequest(
            op: .audioConvert, options: .audio(.convert(.m4aALAC)), inputs: sources, omittedStreams: consent)
        return await engine.run(OperationPlanner.batch(for: request, settings: settings), settings: settings) { _ in }
    }
}
