import CoreGraphics
import CoreImage
import Formats
import Foundation
import Testing

@testable import Engine

@Suite struct EditOverlaysTests {
    @Test func overlayModelRoundTripsAndOldImageEditsDecode() throws {
        let legacy = Data(
            #"{"geometry":{"quarterTurns":1,"straighten":0,"flipHorizontal":false,"flipVertical":false,"crop":{"x":0,"y":0,"width":1,"height":1}},"adjustments":{"style":"original","styleIntensity":1,"values":{}},"autoEnhance":false}"#
                .utf8)
        let decodedLegacy = try JSONDecoder().decode(ImageEdit.self, from: legacy)
        #expect(decodedLegacy.overlays.isEmpty)
        #expect(!decodedLegacy.changesColor)
        #expect(decodedLegacy.geometry.quarterTurns == 1)

        var edit = ImageEdit()
        edit.overlays = [
            EditOverlay(mark: .redaction(rect: EditCrop(x: 0.1, y: 0.2, width: 0.3, height: 0.4), style: .mosaic)),
            EditOverlay(mark: .redaction(rect: EditCrop(x: 0.5, y: 0.5, width: 0.2, height: 0.2), style: .blur)),
            EditOverlay(mark: .redaction(rect: EditCrop(x: 0.7, y: 0.1, width: 0.2, height: 0.2), style: .solid)),
            EditOverlay(
                mark: .box(rect: EditCrop(x: 0.1, y: 0.1, width: 0.4, height: 0.3), color: .red, size: .medium)),
            EditOverlay(
                mark: .arrow(
                    from: EditPoint(x: 0.1, y: 0.2), to: EditPoint(x: 0.8, y: 0.7), color: .blue, size: .large)),
            EditOverlay(mark: .text("Hello", at: EditPoint(x: 0.5, y: 0.5), color: .yellow, size: .small)),
        ]
        #expect(edit.changesColor)
        #expect(!edit.isIdentity)
        let encoded = try JSONEncoder().encode(edit)
        let restored = try JSONDecoder().decode(ImageEdit.self, from: encoded)
        #expect(restored == edit)

        let timed = TimedOverlay(overlay: edit.overlays[0], sourceIndex: 1, start: 0.5, end: 2.5)
        let restoredTimed = try JSONDecoder().decode(TimedOverlay.self, from: JSONEncoder().encode(timed))
        #expect(restoredTimed == timed)
        #expect(restoredTimed.id == edit.overlays[0].id)
    }

    @Test func overlayValidationEnforcesBoundsCountsAndTextRules() throws {
        var valid = ImageEdit()
        valid.overlays = (0..<EditOverlay.maximumCount).map { _ in
            EditOverlay(mark: .redaction(rect: EditCrop(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .solid))
        }
        try valid.validate()

        var tooMany = valid
        tooMany.overlays.append(
            EditOverlay(mark: .redaction(rect: EditCrop(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .solid)))
        #expect(throws: EngineError.self) { try tooMany.validate() }

        let duplicateID = UUID()
        var duplicate = ImageEdit()
        duplicate.overlays = [
            EditOverlay(id: duplicateID, mark: .box(rect: EditCrop(), color: .red, size: .small)),
            EditOverlay(id: duplicateID, mark: .box(rect: EditCrop(), color: .blue, size: .small)),
        ]
        #expect(throws: EngineError.self) { try duplicate.validate() }

        let invalidMarks: [EditMark] = [
            .redaction(rect: EditCrop(x: 0.9, y: 0, width: 0.2, height: 0.2), style: .mosaic),
            .box(rect: EditCrop(x: -0.1, y: 0, width: 0.2, height: 0.2), color: .red, size: .small),
            .arrow(from: EditPoint(x: 0.5, y: 0.5), to: EditPoint(x: 0.505, y: 0.505), color: .red, size: .small),
            .arrow(from: EditPoint(x: 0.5, y: 0.5), to: EditPoint(x: 0.51, y: 0.5), color: .red, size: .small),
            .arrow(from: EditPoint(x: -0.1, y: 0.5), to: EditPoint(x: 0.5, y: 0.5), color: .red, size: .small),
            .arrow(from: EditPoint(x: 0.1, y: .nan), to: EditPoint(x: 0.5, y: 0.5), color: .red, size: .small),
            .text("", at: EditPoint(x: 0.5, y: 0.5), color: .white, size: .medium),
            .text("   \t  ", at: EditPoint(x: 0.5, y: 0.5), color: .white, size: .medium),
            .text("line1\nline2", at: EditPoint(x: 0.5, y: 0.5), color: .white, size: .medium),
            .text(String(repeating: "a", count: 201), at: EditPoint(x: 0.5, y: 0.5), color: .white, size: .medium),
            .text("ok", at: EditPoint(x: 1.1, y: 0.5), color: .white, size: .medium),
        ]
        for mark in invalidMarks {
            var edit = ImageEdit()
            edit.overlays = [EditOverlay(mark: mark)]
            #expect(throws: EngineError.self) { try edit.validate() }
        }

        var boundaryText = ImageEdit()
        boundaryText.overlays = [
            EditOverlay(
                mark: .text(
                    " " + String(repeating: "x", count: 200) + " ",
                    at: EditPoint(x: 0, y: 1), color: .black, size: .large)),
            EditOverlay(
                mark: .arrow(
                    from: EditPoint(x: 0.5, y: 0.5), to: EditPoint(x: 0.511, y: 0.5), color: .green, size: .small)),
        ]
        try boundaryText.validate()
    }

    @Test func geometryPointMappingRoundTripsAcrossAllTransforms() throws {
        let canvas = CGSize(width: 240, height: 160)
        let samples = [
            EditPoint(x: 0.0, y: 0.0),
            EditPoint(x: 1.0, y: 0.0),
            EditPoint(x: 0.0, y: 1.0),
            EditPoint(x: 0.25, y: 0.6),
            EditPoint(x: 0.72, y: 0.31),
        ]
        let crops = [EditCrop(), EditCrop(x: 0.15, y: 0.2, width: 0.55, height: 0.6)]
        let angles = [-32.0, 0.0, 17.5, 45.0]
        for turns in 0...3 {
            for flipHorizontal in [false, true] {
                for flipVertical in [false, true] {
                    for straighten in angles {
                        for crop in crops {
                            for includingCrop in [false, true] {
                                var geometry = EditGeometry()
                                geometry.quarterTurns = turns
                                geometry.flipHorizontal = flipHorizontal
                                geometry.flipVertical = flipVertical
                                geometry.straighten = straighten
                                geometry.crop = crop
                                for point in samples {
                                    let mapped = geometry.outputPoint(
                                        point, canvas: canvas, includingCrop: includingCrop)
                                    let roundTrip = geometry.canvasPoint(
                                        mapped, canvas: canvas, includingCrop: includingCrop)
                                    #expect(abs(roundTrip.x - point.x) < 1e-9)
                                    #expect(abs(roundTrip.y - point.y) < 1e-9)
                                }
                            }
                        }
                    }
                }
            }
        }

        let source = try ImageFixtures.canvas(width: 120, height: 80) { context in
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
            context.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
            context.fill(CGRect(x: 24, y: 54, width: 12, height: 12))
        }
        var geometry = EditGeometry()
        geometry.quarterTurns = 1
        geometry.flipHorizontal = true
        geometry.crop = EditCrop(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        let rendered = try ImagePixels.render(geometry.applying(to: CIImage(cgImage: source)), like: source)
        let mapped = geometry.outputPoint(EditPoint(x: 0.25, y: 0.25), canvas: CGSize(width: 120, height: 80))
        let px = Int((mapped.x * Double(rendered.width)).rounded())
        let py = Int((mapped.y * Double(rendered.height)).rounded())
        let pixel = try ImageFixtures.pixel(rendered, x: px, y: py)
        #expect(pixel[1] > 230 && pixel[0] < 20 && pixel[2] < 20)
    }

    @Test(arguments: RedactionStyle.allCases)
    func redactionsModifyInsideRegionAndPreserveOutsidePixels(style: RedactionStyle) throws {
        let source = try checkerboard(width: 160, height: 120, tile: 4)
        let rect = EditCrop(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        var edit = ImageEdit()
        edit.overlays = [EditOverlay(mark: .redaction(rect: rect, style: style))]
        let rendered = try ImagePixels.render(
            PhotoEditing.image(source, edit: edit, automaticFilters: []), like: source)

        var insideDiffCount = 0
        for y in stride(from: 34, to: 86, by: 2) {
            for x in stride(from: 44, to: 116, by: 2) {
                let before = try ImageFixtures.pixel(source, x: x, y: y)
                let after = try ImageFixtures.pixel(rendered, x: x, y: y)
                if style == .solid {
                    #expect(after[0] == 0 && after[1] == 0 && after[2] == 0 && after[3] == 255)
                }
                if zip(before, after).contains(where: { abs(Int($0) - Int($1)) > 20 }) {
                    insideDiffCount += 1
                }
            }
        }
        #expect(insideDiffCount > 50)

        for point in [(4, 4), (155, 4), (4, 115), (155, 115), (20, 60), (140, 60)] {
            let before = try ImageFixtures.pixel(source, x: point.0, y: point.1)
            let after = try ImageFixtures.pixel(rendered, x: point.0, y: point.1)
            #expect(before == after)
        }
    }

    @Test func redactionFollowsSensitiveContentAcrossRotationAndCrop() throws {
        let source = try ImageFixtures.canvas(width: 120, height: 80) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 60, height: 80))
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 60, y: 0, width: 60, height: 80))
        }
        var edit = ImageEdit()
        edit.geometry.quarterTurns = 1
        edit.geometry.crop = EditCrop(x: 0, y: 0, width: 1, height: 0.5)
        edit.overlays = [
            EditOverlay(mark: .redaction(rect: EditCrop(x: 0, y: 0, width: 0.5, height: 1), style: .solid))
        ]
        let rendered = try ImagePixels.render(
            PhotoEditing.image(source, edit: edit, automaticFilters: []), like: source)
        let center = try ImageFixtures.pixel(rendered, x: rendered.width / 2, y: rendered.height / 2)
        #expect(center[0] == 0 && center[1] == 0 && center[2] == 0)
    }

    @Test func annotationsIgnoreStylesAndStayUntintedAfterMonochrome() throws {
        let source = try ImageFixtures.canvas(width: 240, height: 160) { context in
            context.setFillColor(CGColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 160))
        }
        var edit = ImageEdit()
        edit.adjustments.style = .monochrome
        edit.overlays = [
            EditOverlay(
                mark: .arrow(
                    from: EditPoint(x: 0.2, y: 0.5), to: EditPoint(x: 0.8, y: 0.5), color: .red, size: .large)),
            EditOverlay(
                mark: .box(rect: EditCrop(x: 0.1, y: 0.1, width: 0.8, height: 0.2), color: .blue, size: .large)),
            EditOverlay(mark: .text("TEST", at: EditPoint(x: 0.5, y: 0.8), color: .yellow, size: .large)),
        ]
        let rendered = try ImagePixels.render(
            PhotoEditing.image(source, edit: edit, automaticFilters: []), like: source)

        let arrowPixel = try ImageFixtures.pixel(rendered, x: 120, y: 80)
        #expect(arrowPixel[0] > 200 && arrowPixel[1] < 80 && arrowPixel[2] < 80)

        let boxPixel = try ImageFixtures.pixel(rendered, x: 120, y: 16)
        #expect(boxPixel[2] > 200 && boxPixel[0] < 80)

        var yellowPixels = 0
        for y in 115...145 {
            for x in 80...160 {
                let pixel = try ImageFixtures.pixel(rendered, x: x, y: y)
                if pixel[0] > 200 && pixel[1] > 160 && pixel[2] < 80 { yellowPixels += 1 }
            }
        }
        #expect(yellowPixels > 20)
    }

    @Test func photoPreviewAndExportMatchWithOverlaysAfterDownscaling() async throws {
        let folder = try TestVolume.makeFolder()
        let url = try ImageFixtures.write(
            [try checkerboard(width: 480, height: 320, tile: 8)], as: .png, to: folder.appending(path: "source.png"))
        let source = try await PhotoEditorSource.open(url)
        var edit = ImageEdit()
        edit.geometry.crop = EditCrop(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        edit.adjustments.style = .monochrome
        edit.overlays = [
            EditOverlay(mark: .redaction(rect: EditCrop(x: 0.2, y: 0.2, width: 0.25, height: 0.25), style: .solid)),
            EditOverlay(mark: .redaction(rect: EditCrop(x: 0.55, y: 0.2, width: 0.25, height: 0.25), style: .mosaic)),
            EditOverlay(
                mark: .arrow(
                    from: EditPoint(x: 0.2, y: 0.7), to: EditPoint(x: 0.8, y: 0.7), color: .red, size: .medium)),
            EditOverlay(
                mark: .box(rect: EditCrop(x: 0.15, y: 0.55, width: 0.7, height: 0.3), color: .green, size: .medium)),
        ]
        let preview = try await source.render(edit, maximumDimension: 240)
        let outcome = try await ImageFixtures.run(.imageEdit, .edit(edit), inputs: [url], outputMode: .newFile)
        let output = try ImageFixtures.output(of: outcome)
        let exported = try ImageFixtures.image(output)
        let scaledExport = try ImagePixels.scaled(exported, width: preview.width, height: preview.height)

        var totalError = 0
        var samples = 0
        for y in stride(from: 2, to: preview.height - 2, by: 4) {
            for x in stride(from: 2, to: preview.width - 2, by: 4) {
                let left = try ImageFixtures.pixel(preview, x: x, y: y)
                let right = try ImageFixtures.pixel(scaledExport, x: x, y: y)
                for channel in 0..<3 { totalError += abs(Int(left[channel]) - Int(right[channel])) }
                samples += 3
            }
        }
        #expect(Double(totalError) / Double(samples) < 8)
    }

    @Test func hdrPhotoWithOverlayForcesNewSDRFile() async throws {
        let folder = try TestVolume.makeFolder()
        let url = folder.appending(path: "hdr.heic")
        try ImageGainMapIntegrationTests.fixture(url, variant: .apple, heic: true)
        let original = try Data(contentsOf: url)
        var edit = ImageEdit()
        edit.overlays = [
            EditOverlay(mark: .redaction(rect: EditCrop(x: 0.2, y: 0.2, width: 0.4, height: 0.4), style: .solid))
        ]
        let outcome = try await ImageFixtures.run(.imageEdit, .edit(edit), inputs: [url], outputMode: .replace)
        let output = try ImageFixtures.output(of: outcome)
        #expect(output != url)
        #expect(try Data(contentsOf: url) == original)
        let decoded = try await ImageDocument.load(output)
        #expect(!decoded.containsHDR)
        let center = try ImageFixtures.pixel(decoded.first, x: decoded.first.width / 2, y: decoded.first.height / 2)
        #expect(center[0] < 10 && center[1] < 10 && center[2] < 10)
    }

    @Test func fractionalRedactionsCoverEveryEdgeAndReplaceTranslucentPixels() throws {
        let source = try ImageFixtures.canvas(width: 100, height: 100) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5))
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        let cases: [(EditCrop, [(Int, Int)])] = [
            (EditCrop(x: 0.106, y: 0.106, width: 0.2, height: 0.2), [(10, 20), (30, 20), (20, 10), (20, 30)]),
            (EditCrop(x: 0.996, y: 0, width: 0.004, height: 1), [(99, 0), (99, 50), (99, 99)]),
            (EditCrop(x: 0, y: 0, width: 0.004, height: 1), [(0, 0), (0, 50), (0, 99)]),
            (EditCrop(x: 0, y: 0.996, width: 1, height: 0.004), [(0, 99), (50, 99), (99, 99)]),
            (EditCrop(x: 0, y: 0, width: 1, height: 0.004), [(0, 0), (50, 0), (99, 0)]),
        ]
        for (rect, probes) in cases {
            let overlays = [EditOverlay(mark: .redaction(rect: rect, style: .solid))]
            let rendered = try ImagePixels.render(overlays.redacting(CIImage(cgImage: source)), like: source)
            for (x, y) in probes {
                #expect(try ImageFixtures.pixel(rendered, x: x, y: y) == [0, 0, 0, 255])
            }
            #expect(try ImageFixtures.pixel(rendered, x: 50, y: 50) == ImageFixtures.pixel(source, x: 50, y: 50))
        }
    }

    @Test func fractionalCropPointsMatchActualPixelBounds() {
        let canvas = CGSize(width: 101, height: 79)
        var geometry = EditGeometry()
        geometry.crop = EditCrop(x: 0.106, y: 0.117, width: 0.601, height: 0.663)
        let mapped = geometry.outputPoint(EditPoint(x: 11.0 / 101, y: 9.0 / 79), canvas: canvas)
        #expect(abs(mapped.x) < 1e-12)
        #expect(abs(mapped.y) < 1e-12)
        let restored = geometry.canvasPoint(.zero, canvas: canvas)
        #expect(abs(restored.x - 11.0 / 101) < 1e-12)
        #expect(abs(restored.y - 9.0 / 79) < 1e-12)
    }

    @Test func redactionContainsSensitivePixelsAfterStraighten() throws {
        let source = try ImageFixtures.canvas(width: 100, height: 100) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        var edit = ImageEdit()
        edit.geometry.straighten = 23
        edit.overlays = [
            EditOverlay(mark: .redaction(rect: EditCrop(x: 0.306, y: 0.306, width: 0.4, height: 0.4), style: .solid))
        ]
        let rendered = try ImagePixels.render(
            PhotoEditing.image(source, edit: edit, automaticFilters: []), like: source)
        for y in stride(from: 0.311, through: 0.701, by: 0.03) {
            for x in stride(from: 0.311, through: 0.701, by: 0.03) {
                let point = edit.geometry.outputPoint(EditPoint(x: x, y: y), canvas: CGSize(width: 100, height: 100))
                let pixel = try ImageFixtures.pixel(rendered, x: Int(point.x * 100), y: Int(point.y * 100))
                #expect(pixel[0] < 8 && pixel[1] < 8 && pixel[2] < 8)
            }
        }
    }

    @Test func smallTextUsesFullResolutionMinimumInNarrowPhotoPreview() async throws {
        let folder = try TestVolume.makeFolder()
        let source = try ImageFixtures.canvas(width: 4000, height: 400) { context in
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 4000, height: 400))
        }
        let url = try ImageFixtures.write([source], as: .png, to: folder.appending(path: "wide.png"))
        let editor = try await PhotoEditorSource.open(url)
        var edit = ImageEdit()
        edit.overlays = [EditOverlay(mark: .text("SECRET", at: EditPoint(x: 0.5, y: 0.5), color: .white, size: .small))]
        let preview = try await editor.render(edit, maximumDimension: 960)
        let full = try ImagePixels.render(PhotoEditing.image(source, edit: edit, automaticFilters: []), like: source)
        let scaled = try ImagePixels.scaled(full, width: preview.width, height: preview.height)
        for image in [preview, scaled] {
            var rows = Set<Int>()
            for y in 30..<66 {
                for x in 440..<520 {
                    let pixel = try ImageFixtures.pixel(image, x: x, y: y)
                    if pixel[0] > 30 { rows.insert(y) }
                }
            }
            #expect(!rows.isEmpty)
            #expect(rows.count <= 6)
        }
    }

    @Test func blurPreviewUsesFullResolutionRadius() throws {
        let source = try ImageFixtures.canvas(width: 4000, height: 400) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 4000, height: 400))
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 2000, height: 400))
        }
        let overlays = [EditOverlay(mark: .redaction(rect: EditCrop(), style: .blur))]
        let small = try ImagePixels.scaled(source, width: 960, height: 96)
        let preview = try ImagePixels.render(
            overlays.redacting(CIImage(cgImage: small), fullCanvasSize: CGSize(width: 4000, height: 400)), like: small)
        let full = try ImagePixels.render(overlays.redacting(CIImage(cgImage: source)), like: source)
        let scaled = try ImagePixels.scaled(full, width: 960, height: 96)
        for x in 470...490 {
            let actual = try ImageFixtures.pixel(preview, x: x, y: 48)
            let expected = try ImageFixtures.pixel(scaled, x: x, y: 48)
            #expect(abs(Int(actual[0]) - Int(expected[0])) < 8)
        }
    }

    private func checkerboard(width: Int, height: Int, tile: Int) throws -> CGImage {
        try ImageFixtures.canvas(width: width, height: height) { context in
            for row in stride(from: 0, to: height, by: tile) {
                for column in stride(from: 0, to: width, by: tile) {
                    let bright = ((row / tile) + (column / tile)).isMultiple(of: 2)
                    context.setFillColor(
                        bright
                            ? CGColor(srgbRed: 0.95, green: 0.15, blue: 0.15, alpha: 1)
                            : CGColor(srgbRed: 0.1, green: 0.85, blue: 0.9, alpha: 1))
                    context.fill(CGRect(x: column, y: row, width: tile, height: tile))
                }
            }
        }
    }
}
