import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Engine

private enum MirrorImageEdit: CaseIterable {
    case resize, jpegQuarterTurn, pixelQuarterTurn, flip, convert, strip
}

private enum MirroredExif: UInt32, CaseIterable {
    case horizontal = 2
    case vertical = 4
    case transpose = 5
    case transverse = 7

    var corners: [Int] {
        switch self {
        case .horizontal: [1, 0, 3, 2]
        case .vertical: [2, 3, 0, 1]
        case .transpose: [0, 2, 1, 3]
        case .transverse: [3, 1, 2, 0]
        }
    }
}

@Suite(.serialized) struct ImageDisplayTransformTests {
    private static let width = 64
    private static let height = 32
    private static let channelTolerance = 40
    private static let colors: [[UInt8]] = [
        [255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0],
    ]

    private static func markedImage() throws -> CGImage {
        try ImageFixtures.canvas(width: width, height: height) { graphics in
            let halfWidth = width / 2
            let halfHeight = height / 2
            for corner in colors.indices {
                let color = colors[corner]
                graphics.setFillColor(
                    CGColor(
                        srgbRed: Double(color[0]) / 255, green: Double(color[1]) / 255,
                        blue: Double(color[2]) / 255, alpha: 1))
                graphics.fill(
                    CGRect(
                        x: corner % 2 * halfWidth, y: corner < 2 ? halfHeight : 0,
                        width: halfWidth, height: halfHeight))
            }
        }
    }

    private static func expectCorners(_ image: CGImage, _ expected: [Int]) throws {
        #expect(expected.count == colors.count)
        for (corner, expectedColor) in expected.enumerated() {
            let pixel = try ImageFixtures.pixel(
                image, x: (corner % 2 == 0 ? 1 : 3) * image.width / 4,
                y: (corner < 2 ? 1 : 3) * image.height / 4)
            for channel in 0..<3 {
                #expect(abs(Int(pixel[channel]) - Int(colors[expectedColor][channel])) < channelTolerance)
            }
        }
    }

    @Test(arguments: MirroredExif.allCases, MirrorImageEdit.allCases)
    private func editsPreserveMirroredExif(orientation: MirroredExif, edit: MirrorImageEdit) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let type: UTType = edit == .pixelQuarterTurn ? .tiff : .jpeg
        let input = try ImageFixtures.write(
            [Self.markedImage()], as: type, to: folder.appending(path: "mirrored.\(type == .tiff ? "tiff" : "jpg")"),
            frameProperties: [
                kCGImagePropertyOrientation: orientation.rawValue,
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "Mirror Lens"],
            ], quality: 1)
        #expect(try ImageFixtures.properties(input)[kCGImagePropertyOrientation] as? UInt32 == orientation.rawValue)
        let original = try Data(contentsOf: input)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        let result: ItemResult
        var expected = orientation.corners
        let swapsAxes = orientation == .transpose || orientation == .transverse
        var outputWidth = swapsAxes ? Self.height : Self.width
        var outputHeight = swapsAxes ? Self.width : Self.height
        switch edit {
        case .resize:
            result = try await ImageEdits.resize(input, ImageResize(size: .percent(50)), context: context)
            outputWidth /= 2
            outputHeight /= 2
        case .jpegQuarterTurn, .pixelQuarterTurn:
            result = try await ImageEdits.rotate(input, degrees: 90, fill: nil, context: context)
            expected = [expected[2], expected[0], expected[3], expected[1]]
            swap(&outputWidth, &outputHeight)
        case .flip:
            result = try await ImageEdits.flip(input, .horizontal, context: context)
            expected = [expected[1], expected[0], expected[3], expected[2]]
        case .convert:
            result = try await ImageEdits.convert(input, ImageConversion(format: .png), context: context)
        case .strip:
            result = try await ImageMetadata.strip(input, fields: [.exif], context: context)
        }
        guard case .replace(let source, let output) = result else {
            Issue.record("expected a staged replacement")
            return
        }
        #expect(source == input)
        #expect(try Data(contentsOf: input) == original)
        let displayed = try await ImageDocument.load(output.url).first
        #expect(displayed.width == outputWidth && displayed.height == outputHeight)
        try Self.expectCorners(displayed, expected)
        if edit == .jpegQuarterTurn {
            #expect(try ImageFixtures.rawBytes(output.url) == ImageFixtures.rawBytes(input))
        }
        if edit != .jpegQuarterTurn, edit != .strip {
            #expect(try ImageFixtures.properties(output.url)[kCGImagePropertyOrientation] as? Int ?? 1 == 1)
        }
    }
}
