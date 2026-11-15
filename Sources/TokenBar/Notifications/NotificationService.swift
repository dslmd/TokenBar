import AppKit
import UserNotifications
import TokenBarCore

/// Shows TokenBar's notifications (texts come from `QuotaAlerts` in TokenBarCore) and tracks whether the
/// user allows them. Only works when running from an app bundle: the notification center refuses a bare
/// executable (`swift run`), so the service then reports `.unavailable` and does nothing.
@MainActor
final class NotificationService: ObservableObject {
    static let shared = NotificationService()

    enum Authorization: Equatable {
        /// Not checked yet.
        case unknown
        /// The user has not been asked yet.
        case notDetermined
        case denied
        case allowed
        /// Not running from an app bundle (development build), so notifications cannot be shown.
        case unavailable
    }

    @Published private(set) var authorization: Authorization = .unknown

    private var snapshotOverride: Authorization?

    var isAvailable: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    private var center: UNUserNotificationCenter? { isAvailable ? UNUserNotificationCenter.current() : nil }

    /// Re-reads the system setting (call when the app or the settings window comes to the front).
    func refreshAuthorization() {
        if let snapshotOverride { authorization = snapshotOverride; return }
        guard let center else { authorization = .unavailable; return }
        center.getNotificationSettings { settings in
            let value: Authorization
            switch settings.authorizationStatus {
            case .notDetermined: value = .notDetermined
            case .denied: value = .denied
            default: value = .allowed
            }
            Task { @MainActor in self.authorization = value }
        }
    }

    /// Asks for permission (the system shows its prompt only the first time).
    func requestAuthorization(completion: ((Bool) -> Void)? = nil) {
        guard let center else { authorization = .unavailable; completion?(false); return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                self.refreshAuthorization()
                completion?(granted)
            }
        }
    }

    func deliver(_ alerts: [PendingAlert]) {
        guard let center, !alerts.isEmpty else { return }
        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.subtitle = alert.subtitle
            content.body = alert.body
            content.sound = .default
            content.threadIdentifier = alert.accountID.uuidString
            center.add(UNNotificationRequest(identifier: alert.id, content: content, trigger: nil))
        }
    }

    /// Opens System Settings > Notifications.
    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")
            ?? URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
        NSWorkspace.shared.open(url)
    }

    /// Fixes the reported state for UI snapshots, so they do not depend on this Mac's settings.
    func setAuthorizationForSnapshot(_ value: Authorization) {
        snapshotOverride = value
        authorization = value
    }
}
