import AppKit
import Engine
import ServiceManagement
import UserNotifications
import os

enum SystemSettingsPane {
    static let filesAndFolders = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
    static let fullDiskAccess = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    static let notifications = Bundle.main.bundleIdentifier.flatMap {
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\($0)")
    }

    static func permissionAccess(_ location: PermissionLocation) -> URL? {
        switch location {
        case .desktop, .documents, .downloads, .removableVolume, .networkVolume: filesAndFolders
        case .trash, .other: fullDiskAccess
        }
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
    static var isOn: Bool { status == .enabled || status == .requiresApproval }

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
