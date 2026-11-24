import AppKit
import SwiftUI

struct FinderStorageBarText {
    var bundle = Bundle.main
    var locale = Locale.current

    func name(_ volume: StorageVolume, startupDisk: Bool) -> String {
        guard startupDisk else { return volume.name }
        return String(
            localized: "storageBar.startupDisk", defaultValue: "\(volume.name) (Startup Disk)", bundle: bundle,
            locale: locale)
    }

    func capacity(_ volume: StorageVolume) -> String {
        guard let capacity = volume.capacity else {
            return String(
                localized: "storageBar.noCapacity", defaultValue: "Capacity unavailable", bundle: bundle,
                locale: locale)
        }
        let available = size(capacity.available)
        let total = size(capacity.total)
        return String(
            localized: "storageBar.available", defaultValue: "\(available) available of \(total)", bundle: bundle,
            locale: locale)
    }

    func selection(_ count: Int) -> String {
        String(localized: "storageBar.selection", defaultValue: "\(count) selected", bundle: bundle, locale: locale)
    }

    func accessibilityValue(_ volume: StorageVolume, startupDisk: Bool, selectionCount: Int?) -> String {
        let parts =
            [name(volume, startupDisk: startupDisk), capacity(volume)]
            + [selectionCount.map(selection)].compactMap { $0 }
        return parts.formatted(.list(type: .and, width: .narrow).locale(locale))
    }

    // Decimal units, like Finder.
    private func size(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file).locale(locale))
    }
}

struct FinderStorageBarView: View {
    let model: FinderStorageBarModel

    var body: some View {
        FinderStorageBarContent(
            volume: model.volume, startupDisk: model.showsStartupDisk, selectionCount: model.selectionCount)
    }
}

struct FinderStorageBarContent: View {
    let volume: StorageVolume?
    let startupDisk: Bool
    let selectionCount: Int?
    var text = FinderStorageBarText()
    @Environment(\.displayScale) private var displayScale

    // Finder's status bar uses 11-point text.
    private static let fontSize: CGFloat = 11
    private static let margin: CGFloat = 16
    private static let spacing: CGFloat = 8
    private static let groupSpacing: CGFloat = 16
    private static let maximumNameWidth: CGFloat = 180

    private enum Detail: CaseIterable {
        case full, withoutName, barAndCount, barOnly

        var showsName: Bool { self == .full }
        var showsCapacityText: Bool { self == .full || self == .withoutName }
        var showsSelection: Bool { self != .barOnly }
    }

    var body: some View {
        Group {
            if let volume {
                ViewThatFits(in: .horizontal) {
                    ForEach(Detail.allCases, id: \.self) { detail in
                        row(volume, detail: detail)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Storage"))
                .accessibilityValue(
                    text.accessibilityValue(volume, startupDisk: startupDisk, selectionCount: selectionCount))
            }
        }
        .font(.system(size: Self.fontSize))
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, Self.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1 / displayScale)
        }
    }

    private func row(_ volume: StorageVolume, detail: Detail) -> some View {
        HStack(spacing: Self.spacing) {
            if detail.showsName {
                Text(verbatim: text.name(volume, startupDisk: startupDisk))
                    .foregroundStyle(.primary)
                    .truncationMode(.middle)
                    .frame(maxWidth: Self.maximumNameWidth, alignment: .leading)
                    .fixedSize()
            }
            if let capacity = volume.capacity {
                StorageCapacityBar(usedFraction: capacity.usedFraction)
            }
            if detail.showsCapacityText || volume.capacity == nil {
                Text(verbatim: text.capacity(volume)).foregroundStyle(.secondary)
            }
            Spacer(minLength: Self.groupSpacing)
            if let selectionCount, detail.showsSelection {
                Text(verbatim: text.selection(selectionCount))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct StorageCapacityBar: View {
    let usedFraction: Double
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let size = CGSize(width: 72, height: 6)
    private static let fillDuration: TimeInterval = 0.18
    private static let contrastBorderWidth: CGFloat = 1

    var body: some View {
        Capsule()
            .fill(Color(nsColor: .quaternaryLabelColor))
            .overlay(alignment: .leading) {
                if usedFraction > 0 {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(Self.size.height, Self.size.width * min(usedFraction, 1)))
                }
            }
            .overlay {
                if contrast == .increased {
                    Capsule().strokeBorder(Color(nsColor: .secondaryLabelColor), lineWidth: Self.contrastBorderWidth)
                }
            }
            .clipShape(Capsule())
            .frame(width: Self.size.width, height: Self.size.height)
            .animation(reduceMotion ? nil : .easeOut(duration: Self.fillDuration), value: usedFraction)
    }
}
