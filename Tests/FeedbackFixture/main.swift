import Foundation

@main
struct FeedbackFixture {
    @MainActor
    static func main() {
        let suiteName = "feedback-fixture-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: "activity.shows")
        let first = SettingsStore(defaults: defaults)
        precondition(first.showsActivity, "v2.2 must enable Activity once")
        precondition(defaults.bool(forKey: "activity.v22Migrated"), "Migration marker must persist")

        first.showsActivity = false
        let second = SettingsStore(defaults: defaults)
        precondition(!second.showsActivity, "A later explicit off must persist")
        second.resetAll()
        precondition(second.showsActivity, "Reset must restore automatic Activity")

        defaults.set("99.0.0", forKey: "availableReleaseVersion")
        defaults.set("https://github.com/TKY-27/MacEase/releases/latest", forKey: "availableReleasePageURL")
        second.language = .english
        let updates = UpdateChecker(settings: second, defaults: defaults)
        precondition(
            updates.availableRelease?.pageURL.absoluteString == "https://macease-site.pages.dev/#download",
            "Stored release must use the English official site")
        precondition(defaults.object(forKey: "availableReleasePageURL") == nil, "Legacy URL must be removed")

        second.language = .japanese
        precondition(
            updates.availableRelease?.pageURL.absoluteString == "https://macease-site.pages.dev/ja/#download",
            "Japanese UI must use the Japanese official site")
        print("Feedback fixture passed")
    }
}
