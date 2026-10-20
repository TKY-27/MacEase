import AppKit
import Engine
import ServiceManagement
import UserNotifications
import os

enum SystemSettingsPane {
    static let fullDiskAccess = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    static let notifications = Bundle.main.bundleIdentifier.flatMap {
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\($0)")
    }

    static func open(_ url: URL?) {
        guard let url else {
            Logger(category: "settings").fault("System Settings link is malformed")
            return
        }
        NSWorkspace.shared.open(url)
    }
}

enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

extension UNUserNotificationCenter {
    static func authorizationStatus() async -> UNAuthorizationStatus {
        await current().notificationSettings().authorizationStatus
    }
}
