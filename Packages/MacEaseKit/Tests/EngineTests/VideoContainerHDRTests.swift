import Foundation
import Testing

@testable import Engine
@testable import Formats

@Suite struct VideoContainerHDRTests {
    private static let colourID: UInt32 = 0x55B0
    private static let transferID: UInt32 = 0x55BA
    private static let masteringID: UInt32 = 0x55D0
    private static let pqTransfer: UInt64 = 16
    private static let hlgTransfer: UInt64 = 18
    private static let sdrTransfer: UInt64 = 1

    private func container(in directory: URL, transfer: UInt64, mastering: Bool) throws -> URL {
        let header = EBML.element(MatroskaID.ebml, EBML.element(MatroskaID.docType, string: "webm"))
        var colour = EBML.element(Self.transferID, unsigned: transfer)
        if mastering { colour += EBML.element(Self.masteringID, []) }
        let dimensions =
            EBML.element(MatroskaID.pixelWidth, unsigned: 64)
            + EBML.element(MatroskaID.pixelHeight, unsigned: 48)
            + EBML.element(Self.colourID, colour)
        let fields =
            EBML.element(MatroskaID.trackNumber, unsigned: 1)
            + EBML.element(MatroskaID.trackType, unsigned: 1)
            + EBML.element(MatroskaID.codecID, string: "V_VP9")
            + EBML.element(MatroskaID.defaultDuration, unsigned: UInt64(Nanoseconds.perSecond))
            + EBML.element(MatroskaID.video, dimensions)
        let tracks = EBML.element(MatroskaID.tracks, EBML.element(MatroskaID.trackEntry, fields))
        let url = directory.appending(path: "colour.webm")
        try Data(header + EBML.element(MatroskaID.segment, tracks)).write(to: url)
        return url
    }

    @Test(arguments: [pqTransfer, hlgTransfer, sdrTransfer])
    func containerColourSignalsReachVideoPreflight(transfer: UInt64) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "VideoColour-\(UUID().uuidString)")
        TestTemporaryFolders.register(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        let url = try container(in: directory, transfer: transfer, mastering: false)
        let input = try await MediaInput.open(url)
        #expect(input.video?.hasContainerHDR == (transfer != Self.sdrTransfer))
        if transfer == Self.sdrTransfer {
            #expect(try await VideoProperties.hdrConfiguration(input) == nil)
            return
        }
        let original = try Data(contentsOf: url)
        for mode in [Settings.OutputMode.replace, .newFile] {
            var settings = Settings()
            settings.outputMode = mode
            let context = ItemContext(
                settings: settings, staging: StagingArea(supportDirectory: directory), progress: { _ in })
            defer { context.removeStaging() }
            await #expect(throws: EngineError.hdrConversionUnsupported) {
                try await VideoEdits.run(.convert(.mkv), url: url, context: context)
            }
            await #expect(throws: EngineError.hdrConversionUnsupported) {
                _ = try await VideoProperties.toneMapsExport(input, context: context)
            }
        }
        #expect(try Data(contentsOf: url) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [url.lastPathComponent])
    }

    @Test func containerOnlyMasteringMetadataCannotDisappear() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "VideoMastering-\(UUID().uuidString)")
        TestTemporaryFolders.register(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        let url = try container(in: directory, transfer: Self.sdrTransfer, mastering: true)
        let input = try await MediaInput.open(url)
        #expect(input.video?.hasContainerHDR == true)
        await #expect(throws: EngineError.hdrConversionUnsupported) {
            _ = try await VideoProperties.hdrConfiguration(input)
        }
    }
}
