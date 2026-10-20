import AppKit
import Engine
import MenuCatalog
@preconcurrency import UserNotifications
import os

@MainActor
final class BatchNotifier: NSObject {
    private enum Identifier {
        static let category = "batch"
        static let undo = "undo"
        static let show = "show"
        static let batchID = "batchID"
    }

    var onUndo: ((UUID) -> Void)?
    var onShow: ((UUID) -> Void)?
    private let settings: SettingsStore
    private let center = UNUserNotificationCenter.current()
    private let logger = Logger(category: "notifications")

    init(settings: SettingsStore) {
        self.settings = settings
        super.init()
        center.delegate = self
        let undo = UNNotificationAction(
            identifier: Identifier.undo,
            title: String(localized: "Undo", comment: "Notification action that reverts a batch")
        )
        let show = UNNotificationAction(
            identifier: Identifier.show,
            title: String(localized: "Show in Finder", comment: "Notification action that reveals outputs"),
            options: [.foreground]
        )
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Identifier.category, actions: [undo, show], intentIdentifiers: [])
        ])
    }

    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func notify(_ outcome: BatchOutcome) {
        let summary = BatchSummary(outcome)
        let content = UNMutableNotificationContent()
        content.title = summary.title
        content.body = summary.body
        if outcome.record != nil {
            content.categoryIdentifier = Identifier.category
            content.userInfo = [Identifier.batchID: outcome.batchID.uuidString]
        }
        post(content, id: outcome.batchID.uuidString)
    }

    func notifyStaleMenu() {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "The MacEase menu was updated", comment: "Stale menu notification title")
        content.body = String(localized: "Please choose the item again.", comment: "Stale menu notification body")
        post(content, id: UUID().uuidString)
    }

    func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        post(content, id: UUID().uuidString)
    }

    private func post(_ content: UNMutableNotificationContent, id: String) {
        guard settings.notificationsEnabled else { return }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { [logger] error in
            if let error { logger.error("Notification failed: \(error.localizedDescription, privacy: .public)") }
        }
    }
}

extension BatchNotifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        guard let idString = response.notification.request.content.userInfo[Identifier.batchID] as? String,
            let id = UUID(uuidString: idString)
        else { return }
        await MainActor.run {
            switch action {
            case Identifier.undo: onUndo?(id)
            case Identifier.show, UNNotificationDefaultActionIdentifier: onShow?(id)
            default: break
            }
        }
    }
}
