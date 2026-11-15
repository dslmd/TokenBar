import SwiftUI
import TokenBarCore

/// Page 3: online quota, notifications and where to find TokenBar afterwards.
struct OnboardingAlertsPage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var notifications = NotificationService.shared
    /// The threshold to bring back when notifications are turned on again.
    @State private var rememberedThreshold: Int?

    var body: some View {
        VStack(spacing: 0) {
            OnboardingPageHeader(title: "Quota and notifications",
                                 subtitle: "Choose how TokenBar keeps an eye on your limits. You can change this later in Settings.")
            Form {
                Section {
                    Toggle("Check quota online", isOn: onlineQuota)
                        .toggleStyle(.switch)
                } footer: {
                    OnboardingFooterText("TokenBar reads the sign-in each CLI already saved and asks Anthropic, OpenAI, Google and muse.ai for your quota. Turn it off to keep everything on this Mac.")
                }
                Section {
                    Toggle("Notify me before I hit a limit", isOn: notify)
                        .toggleStyle(.switch)
                    if model.settings.quotaAlertThreshold != nil {
                        Picker("When a quota reaches", selection: threshold) {
                            ForEach(AppSettings.quotaAlertThresholdChoices, id: \.self) { value in
                                Text("\(value)%").tag(value)
                            }
                        }
                    }
                } footer: {
                    permissionFooter
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .onAppear { notifications.refreshAuthorization() }

            OnboardingMenuBarNote()
                .padding(.horizontal, OnboardingMetrics.formInset)
                .padding(.bottom, 14)
        }
    }

    @ViewBuilder private var permissionFooter: some View {
        if model.settings.quotaAlertThreshold != nil {
            switch notifications.authorization {
            case .denied:
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    OnboardingFooterText("Notifications are turned off for TokenBar in System Settings.")
                    Button("Open System Settings") { notifications.openSystemSettings() }
                        .controlSize(.small)
                }
            case .notDetermined:
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    OnboardingFooterText("TokenBar needs your permission to send notifications.")
                    Button("Allow notifications") { notifications.requestAuthorization() }
                        .controlSize(.small)
                }
            case .unavailable:
                OnboardingFooterText("Notifications only work when TokenBar runs as an installed app.")
            case .unknown, .allowed:
                EmptyView()
            }
        }
    }

    private var onlineQuota: Binding<Bool> {
        Binding(get: { model.settings.onlineQuotaEnabled },
                set: { value in model.updateSettings { $0.onlineQuotaEnabled = value } })
    }

    private var notify: Binding<Bool> {
        Binding(get: { model.settings.quotaAlertThreshold != nil },
                set: { enabled in
                    if !enabled, let current = model.settings.quotaAlertThreshold { rememberedThreshold = current }
                    let value = OnboardingAlerts.threshold(enabled: enabled, remembered: rememberedThreshold)
                    withAnimation(.easeInOut(duration: 0.15)) {
                        model.updateSettings { $0.quotaAlertThreshold = value }
                    }
                    if enabled { notifications.requestAuthorization() }
                })
    }

    private var threshold: Binding<Int> {
        Binding(get: {
                    model.settings.quotaAlertThreshold
                        ?? OnboardingAlerts.threshold(enabled: true, remembered: rememberedThreshold)
                        ?? AppSettings.defaultQuotaAlertThreshold
                },
                set: { value in
                    rememberedThreshold = value
                    guard model.settings.quotaAlertThreshold != nil else { return }
                    model.updateSettings { $0.quotaAlertThreshold = value }
                })
    }
}

/// Explanation under a form section, left-aligned with the rows' text.
struct OnboardingFooterText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 10)
    }
}

/// "TokenBar lives in the menu bar", with the real label drawn on a small menu bar strip.
struct OnboardingMenuBarNote: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            OnboardingMenuBarHint(model: model)
            VStack(alignment: .leading, spacing: 2) {
                Text("TokenBar lives in the menu bar")
                    .font(.headline)
                Text("Click it any time to see today's use and your quotas.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct OnboardingMenuBarHint: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            MenuBarLabel(model: model)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.12)))
            Image(systemName: "wifi")
                .foregroundStyle(.secondary)
            Image(systemName: "battery.100")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1))
        )
        .fixedSize()
        .accessibilityHidden(true)
    }
}
