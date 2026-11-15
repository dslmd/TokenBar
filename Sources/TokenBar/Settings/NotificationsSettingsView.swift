import SwiftUI
import TokenBarCore

/// Notifications tab: quota alerts with a threshold, sign-in alerts, and whether macOS lets TokenBar notify.
struct NotificationsSettingsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var service = NotificationService.shared

    var body: some View {
        let quotaOn = SettingsRules.quotaAlertsOn(model.settings.quotaAlertThreshold)
        Form {
            Section {
                Toggle("Notify me before I hit a limit", isOn: Binding(
                    get: { quotaOn },
                    set: { on in
                        model.updateSettings { $0.quotaAlertThreshold = SettingsRules.threshold(afterToggle: on, current: $0.quotaAlertThreshold) }
                        askIfNeeded(turningOn: on)
                    }))
                Picker("When a quota reaches", selection: Binding(
                    get: { SettingsRules.thresholdPickerValue(model.settings.quotaAlertThreshold) },
                    set: { v in model.updateSettings { $0.quotaAlertThreshold = v } })) {
                    ForEach(AppSettings.quotaAlertThresholdChoices, id: \.self) { Text("\($0)%").tag($0) }
                }
                .disabled(!quotaOn)
            } header: {
                Text("Quota alerts")
            } footer: {
                SettingsFooter("One notification per quota window and account, until the window resets.")
            }

            Section("Sign-in problems") {
                Toggle("Notify me when a sign-in needs attention", isOn: Binding(
                    get: { model.settings.signInAlertsEnabled },
                    set: { on in
                        model.updateSettings { $0.signInAlertsEnabled = on }
                        askIfNeeded(turningOn: on)
                    }))
            }

            Section("System permission") {
                SettingsPermissionRow(authorization: service.authorization)
            }
        }
        .formStyle(.grouped)
        .onAppear { service.refreshAuthorization() }
    }

    private func askIfNeeded(turningOn: Bool) {
        if SettingsRules.shouldAskForPermission(turningOn: turningOn, permissionNotDetermined: service.authorization == .notDetermined) {
            service.requestAuthorization()
        }
    }
}

/// The state of the macOS notification permission, with the one action that helps.
private struct SettingsPermissionRow: View {
    let authorization: NotificationService.Authorization

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            switch authorization {
            case .notDetermined:
                Button("Allow notifications") { NotificationService.shared.requestAuthorization() }
            case .denied, .allowed:
                Button("Open System Settings") { NotificationService.shared.openSystemSettings() }
            case .unknown:
                ProgressView().controlSize(.small)
            case .unavailable:
                EmptyView()
            }
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch authorization {
        case .allowed: return "checkmark.circle.fill"
        case .denied: return "bell.slash.fill"
        case .notDetermined: return "bell.badge"
        case .unknown: return "bell"
        case .unavailable: return "bell.slash"
        }
    }

    private var tint: Color {
        switch authorization {
        case .allowed: return .green
        case .denied: return .orange
        case .notDetermined: return .accentColor
        case .unknown, .unavailable: return .secondary
        }
    }

    private var title: String {
        switch authorization {
        case .allowed: return "Notifications are allowed"
        case .denied: return "Notifications are turned off for TokenBar"
        case .notDetermined: return "TokenBar has not asked yet"
        case .unknown: return "Checking…"
        case .unavailable: return "Notifications need the app bundle (development build)"
        }
    }

    private var detail: String? {
        switch authorization {
        case .allowed: return "Change the style or sound in System Settings."
        case .denied: return "Turn them on in System Settings > Notifications > TokenBar."
        case .notDetermined: return "macOS asks once whether TokenBar may show notifications."
        case .unknown: return nil
        case .unavailable: return nil
        }
    }
}
