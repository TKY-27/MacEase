import Foundation

/// Differs between debug and release builds.
struct HostConfiguration: Sendable {
    let urlScheme: String
    let supportDirectory: URL

    static let current: HostConfiguration = {
        guard let scheme = Bundle.main.object(forInfoDictionaryKey: "MacEaseURLScheme") as? String,
            let folder = Bundle.main.object(forInfoDictionaryKey: "MacEaseSupportFolder") as? String
        else { preconditionFailure("Info.plist lacks the MacEase keys") }
        let support = URL.applicationSupportDirectory.appending(path: folder, directoryHint: .isDirectory)
        return HostConfiguration(urlScheme: scheme, supportDirectory: support)
    }()

    var menuFile: URL { supportDirectory.appending(path: "menu.json") }
}
