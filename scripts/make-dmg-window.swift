// Usage: make-dmg-window.swift background | layout <volume>
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// Window geometry in points, y-down like Finder.
let windowSize = CGSize(width: 600, height: 360)
let windowOrigin = CGPoint(x: 200, y: 140)
let iconSize: CGFloat = 128
let labelTextSize: CGFloat = 13
let appCenter = CGPoint(x: 160, y: 164)
let applicationsCenter = CGPoint(x: 440, y: 164)
// Pale: Finder labels stay black over pictures.
let groundColor: UInt32 = 0xF4F6FA
let rowColors: [UInt32] = [0x4FA2FF, 0x1F66EE]
let markColor: UInt32 = 0xFFFFFF
// Proportions follow the app icon's highlighted row.
let rowSize = CGSize(width: 112, height: 32)
let labelBar = CGRect(x: 14, y: -3, width: 50, height: 6)
let chevronInset: CGFloat = 13
let chevronHalfHeight: CGFloat = 7
let chevronDepth: CGFloat = 7
let chevronWeight: CGFloat = 3.25
let renderScales = [1, 2]

let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let backgroundAsset = repository.appending(path: "scripts/dmg-background.tiff")
let backgroundFolder = ".background"
let backgroundName = "background.tiff"
let appName = "MacEase.app"
let applicationsName = "Applications"

func channels(_ hex: UInt32) -> [Double] {
    [hex >> 16, hex >> 8, hex].map { Double($0 & 0xFF) / 255 }
}

func srgb(_ hex: UInt32) -> CGColor {
    let rgb = channels(hex)
    return CGColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
}

// The icon's highlighted row, aimed at Applications.
func drawHighlightedRow(_ context: CGContext) {
    let center = CGPoint(x: (appCenter.x + applicationsCenter.x) / 2, y: appCenter.y)
    let row = CGRect(
        x: center.x - rowSize.width / 2, y: center.y - rowSize.height / 2, width: rowSize.width,
        height: rowSize.height)
    guard let gradient = CGGradient(colorsSpace: nil, colors: rowColors.map(srgb) as CFArray, locations: nil)
    else { fatalError("Gradient creation failed") }
    context.saveGState()
    context.addPath(Capsule(style: .continuous).path(in: row).cgPath)
    context.clip()
    context.drawLinearGradient(
        gradient, start: CGPoint(x: 0, y: row.minY), end: CGPoint(x: 0, y: row.maxY), options: [])
    context.restoreGState()
    context.addPath(Capsule().path(in: labelBar.offsetBy(dx: row.minX, dy: center.y)).cgPath)
    context.setFillColor(srgb(markColor))
    context.fillPath()
    let tipX = row.maxX - chevronInset
    let chevron = CGMutablePath()
    chevron.addLines(between: [
        CGPoint(x: tipX - chevronDepth, y: center.y - chevronHalfHeight), CGPoint(x: tipX, y: center.y),
        CGPoint(x: tipX - chevronDepth, y: center.y + chevronHalfHeight),
    ])
    context.addPath(chevron)
    context.setLineWidth(chevronWeight)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(srgb(markColor))
    context.strokePath()
}

func renderBackground(scale: Int) -> CGImage {
    let width = Int(windowSize.width) * scale
    let height = Int(windowSize.height) * scale
    guard
        let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { fatalError("Bitmap context creation failed") }
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    context.setFillColor(srgb(groundColor))
    context.fill(CGRect(origin: .zero, size: windowSize))
    drawHighlightedRow(context)
    guard let image = context.makeImage() else { fatalError("Image creation failed") }
    return image
}

// Finder picks Retina pages by doubled DPI.
func writeBackground() {
    let lzw = 5
    guard
        let destination = CGImageDestinationCreateWithURL(
            backgroundAsset as CFURL, UTType.tiff.identifier as CFString, renderScales.count, nil)
    else { fatalError("Cannot create \(backgroundAsset.path)") }
    for scale in renderScales {
        let dpi = 72 * scale
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: lzw],
        ]
        CGImageDestinationAddImage(destination, renderBackground(scale: scale), properties as CFDictionary)
    }
    guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write \(backgroundAsset.path)") }
    print("Wrote \(backgroundAsset.path)")
}

extension Data {
    mutating func appendBigEndian<Value: FixedWidthInteger>(_ value: Value) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendASCII(_ text: String) {
        append(contentsOf: Array(text.utf8))
    }

    mutating func appendPascal(_ text: String, capacity: Int) {
        let bytes = Array(text.utf8.prefix(capacity - 1))
        append(UInt8(bytes.count))
        append(contentsOf: bytes + Array(repeating: 0, count: capacity - 1 - bytes.count))
    }

    mutating func appendUTF16(_ text: String) {
        let units = Array(text.utf16)
        appendBigEndian(UInt16(units.count))
        units.forEach { appendBigEndian($0) }
    }
}

enum AliasTag: Int16 {
    case folderName = 0
    case folderNumbers = 1
    case carbonPath = 2
    case unicodeFileName = 14
    case unicodeVolumeName = 15
    case volumeDate = 16
    case fileDate = 17
    case relativePath = 18
    case mountPoint = 19
    case end = -1
}

// Finder stores backgrounds as version-2 alias records.
struct AliasRecord {
    static let macEpochOffset: TimeInterval = 2_082_844_800
    static let highResolutionFactor: UInt64 = 65_536

    let target: URL
    let volume: URL

    func macSeconds(_ date: Date) -> UInt32 {
        UInt32(date.timeIntervalSince1970 + Self.macEpochOffset)
    }

    func fileNumber(_ url: URL) throws -> UInt32 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attributes[.systemFileNumber] as? Int else { fatalError("No file number: \(url.path)") }
        return UInt32(number)
    }

    func extra(_ tag: AliasTag, _ value: Data, into record: inout Data) {
        record.appendBigEndian(tag.rawValue)
        record.appendBigEndian(UInt16(value.count))
        record.append(value)
        if value.count % 2 == 1 { record.append(0) }
    }

    func encoded() throws -> Data {
        let volumeValues = try volume.resourceValues(forKeys: [.volumeNameKey, .volumeCreationDateKey])
        guard let volumeName = volumeValues.volumeName, let volumeDate = volumeValues.volumeCreationDate,
            let fileDate = try target.resourceValues(forKeys: [.creationDateKey]).creationDate
        else { fatalError("Missing volume or file metadata") }
        let folder = target.deletingLastPathComponent()
        let folderNumber = try fileNumber(folder)
        let fileName = target.lastPathComponent
        let relativePath = "/" + folder.lastPathComponent + "/" + fileName
        let fileKind: Int16 = 0
        let fixedDisk: Int16 = 0
        let unknownLevels: Int16 = -1
        let aliasVersion: UInt16 = 2

        var record = Data()
        record.appendBigEndian(fileKind)
        record.appendPascal(volumeName, capacity: 28)
        record.appendBigEndian(macSeconds(volumeDate))
        record.appendASCII("H+")
        record.appendBigEndian(fixedDisk)
        record.appendBigEndian(folderNumber)
        record.appendPascal(fileName, capacity: 64)
        record.appendBigEndian(try fileNumber(target))
        record.appendBigEndian(macSeconds(fileDate))
        record.append(Data(count: 8))
        record.appendBigEndian(unknownLevels)
        record.appendBigEndian(unknownLevels)
        record.append(Data(count: 16))

        var value = Data()
        extra(.folderName, Data(folder.lastPathComponent.utf8), into: &record)
        value.appendBigEndian(UInt64(macSeconds(volumeDate)) * Self.highResolutionFactor)
        extra(.volumeDate, value, into: &record)
        value = Data()
        value.appendBigEndian(UInt64(macSeconds(fileDate)) * Self.highResolutionFactor)
        extra(.fileDate, value, into: &record)
        value = Data()
        value.appendBigEndian(folderNumber)
        extra(.folderNumbers, value, into: &record)
        extra(.carbonPath, Data("\(volumeName):\(folder.lastPathComponent):\(fileName)".utf8), into: &record)
        value = Data()
        value.appendUTF16(fileName)
        extra(.unicodeFileName, value, into: &record)
        value = Data()
        value.appendUTF16(volumeName)
        extra(.unicodeVolumeName, value, into: &record)
        extra(.relativePath, Data(relativePath.utf8), into: &record)
        extra(.mountPoint, Data(volume.path.utf8), into: &record)
        extra(.end, Data(), into: &record)

        let headerSize = 8
        var header = Data(count: 4)
        header.appendBigEndian(UInt16(headerSize + record.count))
        header.appendBigEndian(aliasVersion)
        return header + record
    }
}

enum StoreValue {
    case blob(Data)
    case long(UInt32)
    case type(String)
}

struct StoreRecord {
    let name: String
    let code: String
    let value: StoreValue

    var encoded: Data {
        var data = Data()
        data.appendBigEndian(UInt32(name.utf16.count))
        name.utf16.forEach { data.appendBigEndian($0) }
        data.appendASCII(code)
        switch value {
        case .blob(let bytes):
            data.appendASCII("blob")
            data.appendBigEndian(UInt32(bytes.count))
            data.append(bytes)
        case .long(let number):
            data.appendASCII("long")
            data.appendBigEndian(number)
        case .type(let fourCC):
            data.appendASCII("type")
            data.appendASCII(fourCC)
        }
        return data
    }
}

// The .DS_Store file's buddy allocator.
struct BuddyAllocator {
    static let addressBits = 31
    static let minimumWidth = 5
    var freeOffsets = Array(repeating: [UInt32](), count: addressBits + 1)

    init() { freeOffsets[Self.addressBits] = [0] }

    mutating func allocate(_ size: Int) -> (offset: UInt32, width: Int) {
        let width = max(Self.minimumWidth, Int.bitWidth - (size - 1).leadingZeroBitCount)
        guard var level = (width...Self.addressBits).first(where: { !freeOffsets[$0].isEmpty })
        else { fatalError("Allocator exhausted") }
        let offset = freeOffsets[level].removeFirst()
        while level > width {
            level -= 1
            freeOffsets[level].append(offset + 1 << level)
        }
        return (offset, width)
    }
}

func binaryPlist(_ value: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
}

func iconLocation(_ center: CGPoint) -> Data {
    var data = Data()
    data.appendBigEndian(UInt32(center.x))
    data.appendBigEndian(UInt32(center.y))
    data.append(Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0]))
    return data
}

func layoutRecords(volume: URL) throws -> [StoreRecord] {
    let background = volume.appending(path: backgroundFolder).appending(path: backgroundName)
    let ground = channels(groundColor)
    let bounds =
        "{{\(Int(windowOrigin.x)), \(Int(windowOrigin.y))}, {\(Int(windowSize.width)), \(Int(windowSize.height))}}"
    let windowSettings: [String: Any] = [
        "WindowBounds": bounds, "ShowSidebar": false, "ContainerShowSidebar": false, "ShowToolbar": false,
        "ShowStatusBar": false, "ShowPathbar": false, "ShowTabView": false, "PreviewPaneVisibility": false,
    ]
    let pictureBackground = 2
    let iconView: [String: Any] = [
        "viewOptionsVersion": 1, "backgroundType": pictureBackground,
        "backgroundImageAlias": try AliasRecord(target: background, volume: volume).encoded(),
        "backgroundColorRed": ground[0], "backgroundColorGreen": ground[1], "backgroundColorBlue": ground[2],
        "arrangeBy": "none", "gridOffsetX": 0.0, "gridOffsetY": 0.0,
        "gridSpacing": 100.0, "iconSize": Double(iconSize), "textSize": Double(labelTextSize),
        "labelOnBottom": true, "showIconPreview": false, "showItemInfo": false,
        "scrollPositionX": 0.0, "scrollPositionY": 0.0,
    ]
    return [
        StoreRecord(name: ".", code: "bwsp", value: .blob(try binaryPlist(windowSettings))),
        StoreRecord(name: ".", code: "icvl", value: .type("icnv")),
        StoreRecord(name: ".", code: "icvp", value: .blob(try binaryPlist(iconView))),
        StoreRecord(name: ".", code: "vSrn", value: .long(1)),
        StoreRecord(name: ".", code: "vstl", value: .type("icnv")),
        StoreRecord(name: applicationsName, code: "Iloc", value: .blob(iconLocation(applicationsCenter))),
        StoreRecord(name: appName, code: "Iloc", value: .blob(iconLocation(appCenter))),
    ]
}

func storeFile(_ records: [StoreRecord]) -> Data {
    let rootSize = 2048
    let directorySize = 32
    let nodeSize = 4096
    let headerSize = 32
    let addressSlots = 256
    var allocator = BuddyAllocator()
    _ = allocator.allocate(headerSize)
    let root = allocator.allocate(rootSize)
    let directory = allocator.allocate(directorySize)
    let node = allocator.allocate(nodeSize)

    var leaf = Data()
    leaf.appendBigEndian(UInt32(0))
    leaf.appendBigEndian(UInt32(records.count))
    records.forEach { leaf.append($0.encoded) }
    precondition(leaf.count <= nodeSize, "Layout records overflow one B-tree node")

    let blocks = [root, directory, node]
    let directoryID: UInt32 = 1
    let nodeID: UInt32 = 2
    let leafLevels: UInt32 = 0
    var tree = Data()
    [nodeID, leafLevels, UInt32(records.count), 1, UInt32(nodeSize)].forEach { tree.appendBigEndian($0) }

    var table = Data()
    table.appendBigEndian(UInt32(blocks.count))
    table.appendBigEndian(UInt32(0))
    blocks.forEach { table.appendBigEndian($0.offset | UInt32($0.width)) }
    table.append(Data(count: (addressSlots - blocks.count) * 4))
    table.appendBigEndian(UInt32(1))
    table.append(4)
    table.appendASCII("DSDB")
    table.appendBigEndian(directoryID)
    for offsets in allocator.freeOffsets {
        table.appendBigEndian(UInt32(offsets.count))
        offsets.forEach { table.appendBigEndian($0) }
    }
    precondition(table.count <= rootSize, "Allocator table overflows its block")

    let prefix = 4
    var file = Data(count: prefix + Int(node.offset) + nodeSize)
    var header = Data()
    header.appendBigEndian(UInt32(1))
    header.appendASCII("Bud1")
    [root.offset, UInt32(rootSize), root.offset].forEach { header.appendBigEndian($0) }
    file.replaceSubrange(0..<header.count, with: header)
    for (block, contents) in [(root, table), (directory, tree), (node, leaf)] {
        let start = prefix + Int(block.offset)
        file.replaceSubrange(start..<start + contents.count, with: contents)
    }
    return file
}

func writeLayout(volume: URL) throws {
    let records = try layoutRecords(volume: volume)
    let sorted = records.sorted {
        ($0.name.lowercased(), $0.code) < ($1.name.lowercased(), $1.code)
    }
    try storeFile(sorted).write(to: volume.appending(path: ".DS_Store"))
    print("Wrote the window layout to \(volume.path)")
}

switch CommandLine.arguments.dropFirst().first {
case "background":
    writeBackground()
case "layout" where CommandLine.arguments.count == 3:
    try writeLayout(volume: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
default:
    fatalError("Usage: make-dmg-window.swift background | layout <mounted volume>")
}
