import Foundation

public struct MenuValueSlot: Hashable, Identifiable, Sendable {
    public enum Unit: Hashable, Sendable {
        case percent
        case pixels
        case megabytes
    }

    public let id: String
    public let defaultValue: Int
    public let range: ClosedRange<Int>
    public let unit: Unit

    public init(id: String, defaultValue: Int, range: ClosedRange<Int>, unit: Unit) {
        self.id = id
        self.defaultValue = defaultValue
        self.range = range
        self.unit = unit
    }
}

public struct MenuValues: Codable, Equatable, Sendable {
    public static let percentageRange = 1...1000
    public static let pixelRange = 1...16384
    public static let megabyteRange = 1...10000
    public static let bytesPerMegabyte: Int64 = 1_000_000

    public static let slots: [MenuValueSlot] = [
        .init(id: "image.resize/percent-75", defaultValue: 75, range: percentageRange, unit: .percent),
        .init(id: "image.resize/percent-50", defaultValue: 50, range: percentageRange, unit: .percent),
        .init(id: "image.resize/percent-25", defaultValue: 25, range: percentageRange, unit: .percent),
        .init(id: "image.resize/long-3840", defaultValue: 3840, range: pixelRange, unit: .pixels),
        .init(id: "image.resize/long-2560", defaultValue: 2560, range: pixelRange, unit: .pixels),
        .init(id: "image.resize/long-1920", defaultValue: 1920, range: pixelRange, unit: .pixels),
        .init(id: "image.resize/long-1080", defaultValue: 1080, range: pixelRange, unit: .pixels),
        .init(id: "image.resize/long-720", defaultValue: 720, range: pixelRange, unit: .pixels),
        .init(id: "image.resize/long-480", defaultValue: 480, range: pixelRange, unit: .pixels),
        .init(id: "image.resize/long-360", defaultValue: 360, range: pixelRange, unit: .pixels),
        .init(id: "video.resize/percent-50", defaultValue: 50, range: percentageRange, unit: .percent),
        .init(id: "video.resize/2160p", defaultValue: 2160, range: pixelRange, unit: .pixels),
        .init(id: "video.resize/1080p", defaultValue: 1080, range: pixelRange, unit: .pixels),
        .init(id: "video.resize/720p", defaultValue: 720, range: pixelRange, unit: .pixels),
        .init(id: "video.resize/480p", defaultValue: 480, range: pixelRange, unit: .pixels),
        .init(id: "video.resize/360p", defaultValue: 360, range: pixelRange, unit: .pixels),
        .init(id: "video.compress/mb-10", defaultValue: 10, range: megabyteRange, unit: .megabytes),
        .init(id: "video.compress/mb-25", defaultValue: 25, range: megabyteRange, unit: .megabytes),
        .init(id: "video.compress/mb-50", defaultValue: 50, range: megabyteRange, unit: .megabytes),
        .init(id: "video.compress/mb-100", defaultValue: 100, range: megabyteRange, unit: .megabytes),
    ]

    public private(set) var overrides: [String: Int] = [:]

    public init() {}

    public func value(for id: String) -> Int? {
        guard let slot = Self.slots.first(where: { $0.id == id }) else { return nil }
        let value = overrides[id] ?? slot.defaultValue
        return slot.range.contains(value) ? value : nil
    }

    public mutating func set(_ value: Int, for id: String) throws {
        guard let slot = Self.slots.first(where: { $0.id == id }), slot.range.contains(value) else {
            throw MenuValueError.invalidValue
        }
        if value == slot.defaultValue {
            overrides.removeValue(forKey: id)
        } else {
            overrides[id] = value
        }
    }

    public mutating func reset(_ id: String) {
        overrides.removeValue(forKey: id)
    }
}

public enum MenuValueError: Error, Equatable, Sendable {
    case invalidValue
}
