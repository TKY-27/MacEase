import Foundation
import ImageIO
import SwiftUI

struct PreviewImageInfo: Sendable, Equatable {
    enum Field: Hashable, CaseIterable {
        case dimensions, resolution, colorProfile, bitDepth, dynamicRange, camera, lens, captured, location

        var label: Text {
            switch self {
            case .dimensions: Text("Dimensions")
            case .resolution: Text("Resolution")
            case .colorProfile: Text("Color Profile")
            case .bitDepth: Text("Bit Depth")
            case .dynamicRange: Text("Dynamic Range")
            case .camera: Text("Camera")
            case .lens: Text("Lens")
            case .captured: Text("Captured")
            case .location: Text("Location")
            }
        }
    }

    struct Row: Identifiable, Equatable {
        let field: Field
        let value: String
        var id: Field { field }
    }

    private static let exifDateFormat = "yyyy:MM:dd HH:mm:ss"
    private static let exifDateWithOffsetFormat = "yyyy:MM:dd HH:mm:ssxxx"
    // At most 1 means SDR or unknown.
    private static let standardHeadroom: Float = 1

    let pixelSize: CGSize
    let dotsPerInch: CGSize?
    let colorProfile: String?
    let bitDepth: Int?
    let headroom: Float?
    let camera: String?
    let lens: String?
    let captured: Date?
    let hasLocation: Bool

    init(properties: [CFString: Any], pixelSize: CGSize, headroom: Float) {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        self.pixelSize = pixelSize
        dotsPerInch =
            if let width = properties[kCGImagePropertyDPIWidth] as? Double,
                let height = properties[kCGImagePropertyDPIHeight] as? Double, width > 0, height > 0
            {
                CGSize(width: width, height: height)
            } else {
                nil
            }
        colorProfile = Self.text(properties[kCGImagePropertyProfileName])
        bitDepth = (properties[kCGImagePropertyDepth] as? Int).flatMap { $0 > 0 ? $0 : nil }
        self.headroom = headroom > Self.standardHeadroom ? headroom : nil
        camera = Self.camera(
            make: Self.text(tiff[kCGImagePropertyTIFFMake]), model: Self.text(tiff[kCGImagePropertyTIFFModel]))
        lens = Self.text(exif[kCGImagePropertyExifLensModel])
        captured = Self.date(
            Self.text(exif[kCGImagePropertyExifDateTimeOriginal]),
            offset: Self.text(exif[kCGImagePropertyExifOffsetTimeOriginal]))
        hasLocation = gps[kCGImagePropertyGPSLatitude] != nil || gps[kCGImagePropertyGPSLongitude] != nil
    }

    // Coordinates are never shown, only their presence.
    var rows: [Row] {
        var rows = [Row(field: .dimensions, value: "\(Int(pixelSize.width)) × \(Int(pixelSize.height))")]
        if let dotsPerInch {
            let width = Double(dotsPerInch.width).formatted(.number.precision(.fractionLength(0...1)))
            let height = Double(dotsPerInch.height).formatted(.number.precision(.fractionLength(0...1)))
            rows.append(
                Row(
                    field: .resolution,
                    value: width == height
                        ? String(localized: "\(width) dpi") : String(localized: "\(width) × \(height) dpi")))
        }
        if let colorProfile { rows.append(Row(field: .colorProfile, value: colorProfile)) }
        if let bitDepth { rows.append(Row(field: .bitDepth, value: String(localized: "\(bitDepth)-bit"))) }
        if let headroom {
            let ratio = Double(headroom).formatted(.number.precision(.fractionLength(1)))
            rows.append(Row(field: .dynamicRange, value: String(localized: "HDR, \(ratio)× headroom")))
        }
        if let camera { rows.append(Row(field: .camera, value: camera)) }
        if let lens { rows.append(Row(field: .lens, value: lens)) }
        if let captured {
            rows.append(Row(field: .captured, value: captured.formatted(date: .abbreviated, time: .shortened)))
        }
        if hasLocation { rows.append(Row(field: .location, value: String(localized: "Included in the file"))) }
        return rows
    }

    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func camera(make: String?, model: String?) -> String? {
        guard let model else { return make }
        guard let make, model.range(of: make, options: [.caseInsensitive, .anchored]) == nil else { return model }
        return "\(make) \(model)"
    }

    private static func date(_ value: String?, offset: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let offset {
            formatter.dateFormat = exifDateWithOffsetFormat
            if let date = formatter.date(from: value + offset) { return date }
        }
        formatter.dateFormat = exifDateFormat
        return formatter.date(from: value)
    }
}

struct PreviewImageInfoView: View {
    let metadata: PreviewImageInfo
    let reducedSize: CGSize?
    private static let width: CGFloat = 280

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(metadata.rows) { row in
                GridRow {
                    row.field.label.foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(verbatim: row.value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let reducedSize {
                GridRow {
                    Text("Shown At").foregroundStyle(.secondary)
                    Text("\(Int(reducedSize.width)) × \(Int(reducedSize.height)) (reduced)")
                }
            }
        }
        .font(.callout)
        .frame(width: Self.width, alignment: .leading)
        .padding(PreviewLayout.margin)
    }
}
