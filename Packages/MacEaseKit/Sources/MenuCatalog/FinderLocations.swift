import Foundation

public enum FinderLocations {
    public static func notificationName(supportFolder: String) -> Notification.Name {
        Notification.Name("io.github.tky27.MacEase.locations.\(supportFolder)")
    }

    public static func directories(home: URL, volumes: [URL], additionalPaths: [String]) -> Set<URL> {
        var locations = Set(volumes.map(\.standardizedFileURL))
        locations.insert(URL(fileURLWithPath: "/", isDirectory: true))
        locations.insert(home.standardizedFileURL)
        for name in ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"] {
            locations.insert(home.appending(path: name, directoryHint: .isDirectory).standardizedFileURL)
        }
        let cloud = home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
        for location in [cloud, cloud.appending(path: "Desktop"), cloud.appending(path: "Documents")] {
            locations.insert(location.standardizedFileURL)
        }
        for path in additionalPaths where path.hasPrefix("/") && !path.utf8.contains(0) {
            locations.insert(URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL)
        }
        return locations
    }
}
