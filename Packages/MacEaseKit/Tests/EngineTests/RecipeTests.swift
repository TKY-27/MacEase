import CoreGraphics
import CoreText
import Foundation
import ImageIO
import MenuCatalog
import PDFKit
import Testing
import UniformTypeIdentifiers

@testable import Engine

private func recipeImage(in folder: URL, name: String = "photo.png") throws -> URL {
    let url = folder.appending(path: name)
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let canvas = try #require(
        CGContext(
            data: nil, width: 320, height: 160, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let pixels = try #require(canvas.data).assumingMemoryBound(to: UInt8.self)
    var seed: UInt32 = 7
    for index in 0..<(canvas.bytesPerRow * 160) {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        pixels[index] = UInt8(truncatingIfNeeded: seed >> 24)
    }
    let image = try #require(canvas.makeImage())
    let destination = try #require(
        CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return url
}

private func recipeEngine() throws -> JobEngine {
    let support = FileManager.default.temporaryDirectory.appending(path: "MacEaseRecipeTests-\(UUID().uuidString)")
    TestTemporaryFolders.register(support)
    return try JobEngine(supportDirectory: support, concurrency: 2)
}

private func recipeOutputs(_ outcome: BatchOutcome) throws -> [URL] {
    guard case .succeeded(let outputs, _) = try #require(outcome.outcomes.first) else {
        Issue.record("Recipe failed: \(outcome.outcomes)")
        return []
    }
    return outputs
}

@Suite("Finishing recipes")
struct RecipeTests {
    @Test func pdfJPEGVariantsUseTheirOwnQuality() async throws {
        let folder = try TestVolume.makeFolder()
        let source = try recipeImage(in: folder)
        let imageSource = try #require(CGImageSourceCreateWithURL(source as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        let pdf = folder.appending(path: "document.pdf")
        var box = CGRect(x: 0, y: 0, width: 320, height: 160)
        let canvas = try #require(CGContext(pdf as CFURL, mediaBox: &box, nil))
        canvas.beginPDFPage(nil)
        canvas.draw(image, in: box)
        canvas.endPDFPage()
        canvas.closePDF()
        let recipe = Recipe(
            name: "PDF Delivery",
            variants: [
                OutputVariant(output: .pdfPagesJPEG, suffix: "_low", quality: 10, pdfDPI: 72),
                OutputVariant(output: .pdfPagesJPEG, suffix: "_high", quality: 95, pdfDPI: 72),
            ])
        var settings = Settings()
        settings.image.jpegQuality = 1
        let batch = try RecipePlanner.batch(recipe: recipe, inputs: [pdf], settings: settings)
        settings.image.jpegQuality = 100
        let outcome = await (try recipeEngine()).run(batch, settings: settings) { _ in }
        let package = try #require(try recipeOutputs(outcome).first)
        var sizes: [Int] = []
        for suffix in ["low", "high"] {
            let pages = package.appending(path: "document_\(suffix)_pages")
            let output = try #require(
                try FileManager.default.contentsOfDirectory(at: pages, includingPropertiesForKeys: nil).first)
            let encoded = try Data(contentsOf: output)
            let decoded = try #require(CGImageSourceCreateWithData(encoded as CFData, nil))
            #expect(CGImageSourceGetType(decoded) as String? == UTType.jpeg.identifier)
            #expect(CGImageSourceCreateImageAtIndex(decoded, 0, nil) != nil)
            sizes.append(encoded.count)
        }
        #expect(sizes[0] < sizes[1])
    }

    @Test func mixedMediaRulesProducePlayableVideoThumbnailAndPDFExports() async throws {
        let folder = try TestVolume.makeFolder()
        let input = try recipeImage(in: folder)
        let videoSource = try #require(
            Bundle.module.url(forResource: "ffmpeg-h264-aac", withExtension: "mp4", subdirectory: "Resources"))
        let video = folder.appending(path: "clip.mp4")
        try FileManager.default.copyItem(at: videoSource, to: video)
        let pdf = folder.appending(path: "document.pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 100)
        let canvas = try #require(CGContext(pdf as CFURL, mediaBox: &box, nil))
        canvas.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 20, nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "Recipe proof", attributes: [.font: font]))
        canvas.textPosition = CGPoint(x: 20, y: 40)
        CTLineDraw(line, canvas)
        canvas.endPDFPage()
        canvas.closePDF()
        let recipe = Recipe(
            name: "Mixed Delivery",
            variants: [
                OutputVariant(output: .imageJPEG, maximumEdge: 80),
                OutputVariant(output: .videoMP4, maximumEdge: 160),
                OutputVariant(output: .videoThumbnail, suffix: "_thumbnail"),
                OutputVariant(output: .pdf),
                OutputVariant(output: .pdfPagesPNG, pdfDPI: 72),
                OutputVariant(output: .pdfText),
            ])
        let outcome = await (try recipeEngine()).run(
            try RecipePlanner.batch(recipe: recipe, inputs: [input, video, pdf], settings: Settings()),
            settings: Settings()
        ) { _ in }
        let package = try #require(try recipeOutputs(outcome).first)
        #expect(try FileManager.default.contentsOfDirectory(atPath: package.path).count == 6)
        let clip = try await MediaInput.open(package.appending(path: "clip.mp4"))
        #expect(clip.video?.codec == .h264)
        #expect(max(clip.displaySize.width, clip.displaySize.height) <= 160)
        #expect(clip.duration > 0)
        let thumbnail = try #require(
            CGImageSourceCreateWithURL(package.appending(path: "clip_thumbnail.png") as CFURL, nil))
        #expect(CGImageSourceCreateImageAtIndex(thumbnail, 0, nil) != nil)
        #expect(PDFDocument(url: package.appending(path: "document.pdf"))?.pageCount == 1)
        #expect(
            try String(contentsOf: package.appending(path: "document.txt"), encoding: .utf8).contains("Recipe proof"))
        let pageFolder = package.appending(path: "document_pages")
        let page = try #require(
            try FileManager.default.contentsOfDirectory(at: pageFolder, includingPropertiesForKeys: nil).first)
        let pageSource = try #require(CGImageSourceCreateWithURL(page as CFURL, nil))
        let rendered = try #require(CGImageSourceCreateImageAtIndex(pageSource, 0, nil))
        #expect(rendered.width == 200)
        #expect(rendered.height == 100)
        #expect(FileManager.default.fileExists(atPath: input.path))
        #expect(FileManager.default.fileExists(atPath: video.path))
        #expect(FileManager.default.fileExists(atPath: pdf.path))
    }

    @Test func variantsDecodeAtRequestedDimensionsAndKeepOriginalWithOneUndo() async throws {
        let folder = try TestVolume.makeFolder()
        let input = try recipeImage(in: folder)
        let original = try Data(contentsOf: input)
        let recipe = Recipe(
            name: "Delivery",
            variants: [
                OutputVariant(output: .imageJPEG, suffix: "_small", maximumEdge: 80),
                OutputVariant(output: .imagePNG, suffix: "_large", maximumEdge: 160),
            ])
        let engine = try recipeEngine()
        var settings = Settings()
        settings.outputMode = .replace
        let batch = try RecipePlanner.batch(recipe: recipe, inputs: [input], settings: settings)
        settings.image.jpegQuality = 1
        let outcome = await engine.run(batch, settings: settings) { _ in }
        let package = try #require(try recipeOutputs(outcome).first)
        let expected = [("photo_small.jpg", 80, 40), ("photo_large.png", 160, 80)]
        for (name, width, height) in expected {
            let source = try #require(CGImageSourceCreateWithURL(package.appending(path: name) as CFURL, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == width)
            #expect(image.height == height)
        }
        #expect(try Data(contentsOf: input) == original)
        #expect(outcome.record?.recipeExecution?.recipe == recipe)
        #expect(outcome.record?.recipeExecution?.settings.outputMode == .newFile)
        #expect(outcome.record?.items.count == 1)
        let restoredHistory = HistoryStore(supportDirectory: engine.staging.supportDirectory)
        #expect(await restoredHistory.records.first?.recipeExecution?.recipe == recipe)
        _ = try await engine.undo(batch.id)
        #expect(!FileManager.default.fileExists(atPath: package.path))
        #expect(try Data(contentsOf: input) == original)
    }

    @Test func mixedUnsupportedSelectionRefusesWholePackage() async throws {
        let folder = try TestVolume.makeFolder()
        let input = try recipeImage(in: folder)
        let unsupported = folder.appending(path: "notes.txt")
        try Data("Keep me".utf8).write(to: unsupported)
        let recipe = Recipe(name: "Delivery", variants: [OutputVariant(output: .imageJPEG)])
        #expect(throws: RecipeError.unsupportedInput("notes.txt")) {
            try RecipePlanner.validate(recipe: recipe, inputs: [input, unsupported])
        }
        let batch = try RecipePlanner.batch(recipe: recipe, inputs: [input, unsupported], settings: Settings())
        let outcome = await (try recipeEngine()).run(batch, settings: Settings()) { _ in }
        #expect(outcome.record == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "Delivery").path))
    }

    @Test func namesCollideSafelyInsidePackageAndAtDestination() async throws {
        let firstFolder = try TestVolume.makeFolder()
        let secondFolder = try TestVolume.makeFolder()
        let first = try recipeImage(in: firstFolder)
        let second = try recipeImage(in: secondFolder)
        let existing = firstFolder.appending(path: "Delivery")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let sentinel = existing.appending(path: "existing.txt")
        try Data("Existing output".utf8).write(to: sentinel)
        let recipe = Recipe(name: "Delivery", variants: [OutputVariant(output: .imageJPEG, maximumEdge: 80)])
        #expect(throws: RecipeError.destinationRequired) {
            try RecipePlanner.batch(recipe: recipe, inputs: [first, second], settings: Settings())
        }
        let batch = try RecipePlanner.batch(
            recipe: recipe, inputs: [first, second], destination: firstFolder, settings: Settings())
        let outcome = await (try recipeEngine()).run(batch, settings: Settings()) { _ in }
        let package = try #require(try recipeOutputs(outcome).first)
        #expect(package != existing)
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "Existing output")
        let names = try FileManager.default.contentsOfDirectory(atPath: package.path)
        #expect(Set(names) == ["photo.jpg", "photo (2).jpg"])
    }

    @Test func requiredVariantFailureNeverPublishesEarlierSuccess() async throws {
        let folder = try TestVolume.makeFolder()
        let input = try recipeImage(in: folder)
        let recipe = Recipe(
            name: "Delivery",
            variants: [
                OutputVariant(output: .imagePNG, maximumEdge: 80),
                OutputVariant(output: .imageJPEG, targetBytes: 1),
            ])
        let outcome = await (try recipeEngine()).run(
            try RecipePlanner.batch(recipe: recipe, inputs: [input], settings: Settings()), settings: Settings()
        ) { _ in }
        #expect(outcome.record == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "Delivery").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["photo.png"])
    }

    @Test func folderBudgetRetriesAndCountsAllVariants() async throws {
        let folder = try TestVolume.makeFolder()
        let input = try recipeImage(in: folder)
        let limit: Int64 = 8_000
        let recipe = Recipe(
            name: "Delivery",
            variants: [
                OutputVariant(output: .imageJPEG, suffix: "_a", quality: 95),
                OutputVariant(output: .imageJPEG, suffix: "_b", quality: 95),
            ], totalBytes: limit)
        let outcome = await (try recipeEngine()).run(
            try RecipePlanner.batch(recipe: recipe, inputs: [input], settings: Settings()), settings: Settings()
        ) { _ in }
        let package = try #require(try recipeOutputs(outcome).first)
        let children = try FileManager.default.contentsOfDirectory(
            at: package, includingPropertiesForKeys: [.fileSizeKey])
        #expect(children.count == 2)
        let bytes = try children.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        #expect(bytes <= limit)
    }

    @Test func zipBudgetUsesActualArchiveBytesAndUnreachableCapPublishesNothing() async throws {
        let folder = try TestVolume.makeFolder()
        let input = try recipeImage(in: folder)
        let recipe = Recipe(
            name: "Delivery",
            variants: [
                OutputVariant(output: .imageJPEG, maximumEdge: 80)
            ], packaging: .zip, totalBytes: 20_000)
        let outcome = await (try recipeEngine()).run(
            try RecipePlanner.batch(recipe: recipe, inputs: [input], settings: Settings()), settings: Settings()
        ) { _ in }
        let archive = try #require(try recipeOutputs(outcome).first)
        #expect(archive.pathExtension == "zip")
        #expect(try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max <= 20_000)
        var impossible = recipe
        impossible.name = "Impossible"
        impossible.totalBytes = 1
        let failed = await (try recipeEngine()).run(
            try RecipePlanner.batch(recipe: impossible, inputs: [input], settings: Settings()), settings: Settings()
        ) { _ in }
        #expect(failed.record == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "Impossible.zip").path))
    }

    @Test func cancellationLeavesOriginalAndNoPublishedPackage() async throws {
        let folder = try TestVolume.makeFolder()
        let input = try recipeImage(in: folder)
        let original = try Data(contentsOf: input)
        let recipe = Recipe(name: "Delivery", variants: [OutputVariant(output: .imageJPEG)])
        let batch = try RecipePlanner.batch(recipe: recipe, inputs: [input], settings: Settings())
        let engine = try recipeEngine()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await engine.run(batch, settings: Settings()) { _ in }
        }
        let outcome = await task.value
        #expect(outcome.wasCancelled)
        #expect(outcome.record == nil)
        #expect(try Data(contentsOf: input) == original)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "Delivery").path))
    }

    @Test func sourceChangeAtCommitRefusesCompletedPackage() async throws {
        let folder = try TestVolume.makeFolder()
        let input = try recipeImage(in: folder)
        let recipe = Recipe(name: "Delivery", variants: [OutputVariant(output: .imageJPEG, maximumEdge: 80)])
        let planned = try RecipePlanner.batch(recipe: recipe, inputs: [input], settings: Settings())
        let originalWork = try #require(planned.items.first)
        let changed = WorkItem(inputs: [input]) { context in
            let result = try await originalWork.body(context)
            try Data("Changed source".utf8).write(to: input)
            return result
        }
        let outcome = await (try recipeEngine()).run(
            Batch(operation: .filesFinish, items: [changed]), settings: Settings()
        ) { _ in }
        #expect(outcome.record == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "Delivery").path))
        #expect(try Data(contentsOf: input) == Data("Changed source".utf8))
    }

    @Test func libraryPersistsRevisionsDuplicatesAndDeletion() async throws {
        let folder = try TestVolume.makeFolder()
        let store = RecipeStore(supportDirectory: folder)
        let original = try #require(try await store.recipes().first)
        var edited = original
        edited.name = "Edited Recipe"
        let saved = try await store.save(edited)
        #expect(saved.revision == 2)
        let duplicate = try await store.duplicate(saved.id)
        #expect(duplicate.id != saved.id)
        #expect(duplicate.revision == 1)
        try await store.delete(saved.id)
        let reloaded = try await RecipeStore(supportDirectory: folder).recipes()
        #expect(!reloaded.contains { $0.id == saved.id })
        #expect(reloaded.contains { $0 == duplicate })
        let file = folder.appending(path: RecipeStore.fileName)
        let contents = try Data(contentsOf: file)
        #expect(throws: RecipeError.invalidRecipe) {
            try Recipe(name: "../escape", variants: [OutputVariant(output: .imageJPEG)]).validate()
        }
        #expect(try Data(contentsOf: file) == contents)
    }

    @Test func newerLibraryVersionIsRefusedWithoutOverwriting() async throws {
        let folder = try TestVolume.makeFolder()
        let file = folder.appending(path: RecipeStore.fileName)
        let contents = Data("{\"schema\":999,\"recipes\":[]}".utf8)
        try contents.write(to: file)
        let store = RecipeStore(supportDirectory: folder)
        await #expect(throws: RecipeError.unsupportedSchema(999)) { try await store.recipes() }
        await #expect(throws: RecipeError.unsupportedSchema(999)) { try await store.save(Recipe.builtIns[0]) }
        #expect(try Data(contentsOf: file) == contents)
    }

    @Test func concurrentLibraryWritersKeepEverySavedRecipe() async throws {
        let folder = try TestVolume.makeFolder()
        let additions = (0..<8).map { Recipe(name: "Concurrent \($0)", variants: [OutputVariant(output: .imageJPEG)]) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for recipe in additions {
                group.addTask { _ = try await RecipeStore(supportDirectory: folder).save(recipe) }
            }
            try await group.waitForAll()
        }
        let reloaded = try await RecipeStore(supportDirectory: folder).recipes()
        #expect(Set(reloaded.map(\.id)) == Set((Recipe.builtIns + additions).map(\.id)))
    }
}
