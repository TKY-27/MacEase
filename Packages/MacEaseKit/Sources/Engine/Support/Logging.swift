import os

extension Logger {
    public static let subsystem = "io.github.tky27.MacEase"

    public init(category: String) {
        self.init(subsystem: Self.subsystem, category: category)
    }
}
