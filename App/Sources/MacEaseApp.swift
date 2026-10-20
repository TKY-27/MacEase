import AppKit

@main
enum MacEaseApp {
    @MainActor private static let delegate = AppDelegate()

    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
