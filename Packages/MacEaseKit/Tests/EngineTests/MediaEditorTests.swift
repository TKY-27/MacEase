import CoreImage
import Foundation
import MenuCatalog
import Testing

@testable import Engine

@Suite struct MediaEditorTests {
    @Test func olderVideoEditsKeepNeutralAdditions() throws {
        let encoded = Data(#"{"start":0,"speed":1,"trimMode":"exact"}"#.utf8)
        let edit = try JSONDecoder().decode(VideoEdit.self, from: encoded)
        #expect(edit.geometry.isIdentity)
        #expect(edit.adjustments.isIdentity)
        #expect(edit.volume == 1)
        #expect(edit.sourceStamp == nil)
    }

    @Test func rotationAndCropUseDisplayedCoordinates() throws {
        let source = try ImageFixtures.canvas(width: 80, height: 40) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 40, y: 0, width: 40, height: 40))
        }
        var edit = ImageEdit()
        edit.geometry.quarterTurns = 1
        edit.geometry.crop = EditCrop(height: 0.5)
        let rendered = try ImagePixels.render(
            PhotoEditing.image(source, edit: edit, automaticFilters: []), like: source)
        #expect(rendered.width == 40)
        #expect(rendered.height == 40)
        let pixel = try ImageFixtures.pixel(rendered, x: 20, y: 20)
        #expect(pixel[0] > 240)
        #expect(pixel[2] < 10)
    }

    @Test func straighteningCoversTheCanvas() throws {
        let source = try ImageFixtures.canvas(width: 160, height: 80) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 80))
        }
        var edit = ImageEdit()
        edit.geometry.straighten = 23
        let rendered = try ImagePixels.render(
            PhotoEditing.image(source, edit: edit, automaticFilters: []), like: source)
        #expect(rendered.width == 160)
        #expect(rendered.height == 80)
        for point in [(1, 1), (158, 1), (1, 78), (158, 78)] {
            #expect(try ImageFixtures.pixel(rendered, x: point.0, y: point.1)[3] == 255)
        }
    }

    @Test func neutralAndZeroIntensityPreservePixels() throws {
        let source = try ImageFixtures.photo(width: 64, height: 48)
        var edit = ImageEdit()
        edit.adjustments.style = .monochrome
        edit.adjustments.styleIntensity = 0
        #expect(edit.isIdentity)
        let image = try ImagePixels.render(PhotoEditing.image(source, edit: edit, automaticFilters: []), like: source)
        for point in [(0, 0), (30, 22), (63, 47)] {
            let expected = try ImageFixtures.pixel(source, x: point.0, y: point.1)
            let actual = try ImageFixtures.pixel(image, x: point.0, y: point.1)
            #expect(zip(expected, actual).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
        }
    }

    @Test func monochromeRemovesChromaAndRetainsAlpha() throws {
        let source = try ImageFixtures.disc(size: 40, background: nil)
        var edit = ImageEdit()
        edit.adjustments.style = .monochrome
        let image = try ImagePixels.render(PhotoEditing.image(source, edit: edit, automaticFilters: []), like: source)
        let pixel = try ImageFixtures.pixel(image, x: 20, y: 20)
        #expect(abs(Int(pixel[0]) - Int(pixel[1])) <= 1)
        #expect(abs(Int(pixel[1]) - Int(pixel[2])) <= 1)
        #expect(try ImageFixtures.pixel(image, x: 0, y: 0)[3] == 0)
    }

    @Test func editedSourceReplacementIsRejected() async throws {
        let folder = try TestVolume.makeFolder()
        let url = try ImageFixtures.write(
            [try ImageFixtures.photo()], as: .png, to: folder.appending(path: "photo.png"))
        var edit = ImageEdit()
        edit.sourceStamp = try MediaSourceStamp(url: url)
        edit.geometry.crop.width = 0.5
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 10)], ofItemAtPath: url.path)
        let before = try Data(contentsOf: url)
        let outcome = try await ImageFixtures.run(.imageEdit, .edit(edit), inputs: [url])
        #expect(outcome.record?.items.isEmpty ?? true)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func photoPreviewAndExportSharePixelsAndDimensions() async throws {
        let folder = try TestVolume.makeFolder()
        let url = try ImageFixtures.write(
            [try ImageFixtures.photo(width: 100, height: 80)], as: .png, to: folder.appending(path: "photo.png"))
        let original = try Data(contentsOf: url)
        let source = try await PhotoEditorSource.open(url)
        var edit = ImageEdit()
        edit.geometry.crop = EditCrop(x: 0.1, y: 0.2, width: 0.6, height: 0.5)
        edit.adjustments[.exposure] = 0.4
        let preview = try await source.render(edit)
        let outcome = try await ImageFixtures.run(.imageEdit, .edit(edit), inputs: [url], outputMode: .newFile)
        let output = try ImageFixtures.output(of: outcome)
        let saved = try ImageFixtures.image(output)
        #expect(saved.width == 60 && saved.height == 40)
        #expect(preview.width == saved.width && preview.height == saved.height)
        #expect(output.lastPathComponent == "photo_edited.png")
        #expect(try Data(contentsOf: url) == original)
        let expected = try ImageFixtures.pixel(preview, x: 30, y: 20)
        let actual = try ImageFixtures.pixel(saved, x: 30, y: 20)
        #expect(zip(expected, actual).allSatisfy { abs(Int($0) - Int($1)) <= 2 })
    }

    @Test(arguments: [false, true])
    func photoHDRColorEditPreservesSourceAndMatchesSDRPreview(heic: Bool) async throws {
        let folder = try TestVolume.makeFolder()
        let url = folder.appending(path: heic ? "hdr.heic" : "hdr.jpg")
        try ImageGainMapIntegrationTests.fixture(url, variant: .apple, heic: heic)
        let original = try Data(contentsOf: url)
        let source = try await PhotoEditorSource.open(url)
        #expect(await source.details.containsHDR)
        var edit = ImageEdit()
        edit.adjustments[.exposure] = 0.25
        edit.autoEnhance = true
        let preview = try await source.render(edit)
        let repeated = try await source.render(edit)
        #expect(try ImageFixtures.pixel(preview, x: 20, y: 20) == ImageFixtures.pixel(repeated, x: 20, y: 20))
        let outcome = try await ImageFixtures.run(.imageEdit, .edit(edit), inputs: [url], outputMode: .replace)
        let output = try ImageFixtures.output(of: outcome)
        #expect(output != url)
        #expect(try Data(contentsOf: url) == original)
        let decoded = try await ImageDocument.load(output)
        #expect(!decoded.containsHDR)
        #expect(decoded.first.width == preview.width && decoded.first.height == preview.height)
        let expected = try ImageFixtures.pixel(preview, x: 20, y: 20)
        let actual = try ImageFixtures.pixel(decoded.first, x: 20, y: 20)
        #expect(zip(expected, actual).allSatisfy { abs(Int($0) - Int($1)) < 20 })
    }

    @Test func editorRejectsAnimationInsteadOfFlattening() async throws {
        let folder = try TestVolume.makeFolder()
        let url = try ImageFixtures.write(
            [try ImageFixtures.photo(), try ImageFixtures.photo()], as: .gif,
            to: folder.appending(path: "animated.gif"))
        let original = try Data(contentsOf: url)
        await #expect(throws: EngineError.self) { try await PhotoEditorSource.open(url) }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func invalidCropAndAdjustmentsAreRejected() throws {
        var edit = ImageEdit()
        edit.geometry.crop = EditCrop(x: 0.9, width: 0.2)
        #expect(throws: EngineError.self) { try edit.validate() }
        edit = ImageEdit()
        edit.adjustments[.exposure] = .nan
        #expect(throws: EngineError.self) { try edit.validate() }
    }

    @Test(arguments: [Settings.OutputMode.newFile, .replace])
    func photoEditCommitAndUndoProtectOriginal(mode: Settings.OutputMode) async throws {
        let folder = try TestVolume.makeFolder()
        let source = try ImageFixtures.write(
            [try ImageFixtures.photo(width: 100, height: 80)], as: .png,
            to: folder.appending(path: "photo.png"))
        let original = try Data(contentsOf: source)
        let collision = folder.appending(path: "photo_edited.png")
        try original.write(to: collision)
        let engine = try JobEngine(supportDirectory: AudioSignals.temporaryFolder(), concurrency: 1)
        var settings = Settings()
        settings.outputMode = mode
        var edit = ImageEdit()
        edit.geometry.crop = EditCrop(width: 0.5)
        edit.adjustments.style = .monochrome
        let batch = OperationPlanner.batch(
            for: OperationRequest(op: .imageEdit, options: .image(.edit(edit)), inputs: [source]),
            settings: settings)
        let result = await engine.run(batch, settings: settings) { _ in }
        let output = try ImageFixtures.output(of: result)
        #expect(output == source ? mode == .replace : mode == .newFile)
        #expect(output != collision)
        #expect(try ImageFixtures.image(output).width == 50)
        #expect(try Data(contentsOf: collision) == original)
        if mode == .newFile { #expect(try Data(contentsOf: source) == original) }
        let record = try #require(result.record)
        #expect(try await engine.history.undo(record.id) == [.restored])
        #expect(try Data(contentsOf: source) == original)
        #expect(try Data(contentsOf: collision) == original)
        if mode == .newFile { #expect(!FileManager.default.fileExists(atPath: output.path)) }
    }
    @Test func photoBatchKeepsIndependentEditsAndRejectsAnimationPerFile() async throws {
        let folder = try TestVolume.makeFolder()
        let first = try ImageFixtures.write(
            [try ImageFixtures.photo(width: 100, height: 80)], as: .png,
            to: folder.appending(path: "first.png"))
        let second = try ImageFixtures.write(
            [try ImageFixtures.photo(width: 60, height: 40)], as: .png,
            to: folder.appending(path: "second.png"))
        let animated = try ImageFixtures.write(
            [try ImageFixtures.photo(), try ImageFixtures.photo()], as: .gif,
            to: folder.appending(path: "animated.gif"))
        let originals = try [first, second, animated].map { try Data(contentsOf: $0) }
        var crop = ImageEdit()
        crop.geometry.crop.width = 0.5
        crop.sourceStamp = try MediaSourceStamp(url: first)
        var automatic = ImageEdit()
        automatic.autoEnhance = true
        automatic.adjustments.style = .monochrome
        automatic.sourceStamp = try MediaSourceStamp(url: second)
        var refused = crop
        refused.sourceStamp = try MediaSourceStamp(url: animated)
        let photos = [
            PhotoEditInput(url: first, edit: crop), PhotoEditInput(url: second, edit: automatic),
            PhotoEditInput(url: animated, edit: refused),
        ]
        let engine = try JobEngine(supportDirectory: AudioSignals.temporaryFolder(), concurrency: 1)
        var settings = Settings()
        settings.outputMode = .newFile
        let result = await engine.run(MediaEditing.photos(photos, settings: settings), settings: settings) { _ in }
        try #require(result.outcomes.count == 3)
        guard case .succeeded(let firstOutputs, _) = result.outcomes[0],
            case .succeeded(let secondOutputs, _) = result.outcomes[1],
            case .failed = result.outcomes[2]
        else {
            Issue.record("expected two edits and one rejected animation")
            return
        }
        let firstOutput = try #require(firstOutputs.first)
        let secondOutput = try #require(secondOutputs.first)
        #expect(try ImageFixtures.image(firstOutput).width == 50)
        let secondImage = try ImageFixtures.image(secondOutput)
        #expect(secondImage.width == 60 && secondImage.height == 40)
        let pixel = try ImageFixtures.pixel(secondImage, x: 30, y: 20)
        #expect(abs(Int(pixel[0]) - Int(pixel[2])) <= 2)
        for (url, original) in zip([first, second, animated], originals) {
            #expect(try Data(contentsOf: url) == original)
        }
        let record = try #require(result.record)
        #expect(try await engine.history.undo(record.id) == [.restored, .restored])
        #expect(!FileManager.default.fileExists(atPath: firstOutput.path))
        #expect(!FileManager.default.fileExists(atPath: secondOutput.path))
    }

}
