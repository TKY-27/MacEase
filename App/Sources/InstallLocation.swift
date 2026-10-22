import Foundation

struct InstallLocation {
    let bundlePath: String

    static var current: InstallLocation { InstallLocation(bundlePath: Bundle.main.bundlePath) }

    var isTranslocated: Bool { bundlePath.contains("/AppTranslocation/") }

    var isInApplications: Bool {
        let userApplications = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications").path
        return bundlePath.hasPrefix("/Applications/") || bundlePath.hasPrefix(userApplications + "/")
    }
}
