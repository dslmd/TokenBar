import SwiftUI
import TokenBarCore

/// General tab: startup, what the menu bar shows (with a live preview), refresh and online quota.
struct GeneralSettingsView: View {
    @EnvironmentObject var model: AppModel

    private func setting<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(get: { model.settings[keyPath: keyPath] },
                set: { value in model.updateSettings { $0[keyPath: keyPath] = value } })
    }

    var body: some View {
        let showsNumber = model.settings.menuBarShowsNumber
        let tokenOptions = SettingsRules.tokenOptionsApply(model.settings.menuBarMetric, showsNumber: showsNumber)
        Form {
            Section("Startup") {
                Toggle("Open at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }))
                if model.launchAtLoginNeedsApproval {
                    Text("Allow TokenBar in System Settings > General > Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Show number next to the icon", isOn: setting(\.menuBarShowsNumber))
                Picker("Show", selection: setting(\.menuBarMetric)) {
                    ForEach(MenuBarMetric.allCases, id: \.self) { Text(SettingsRules.metricTitle($0)).tag($0) }
                }
                .disabled(!showsNumber)
                Picker("Provider", selection: Binding(
                    get: { model.settings.menuBarProviderID ?? "" },
                    set: { v in model.updateSettings { $0.menuBarProviderID = v.isEmpty ? nil : v } })) {
                    Text("All providers").tag("")
                    ForEach(model.catalog.menuBarProviders) { Text($0.displayName).tag($0.id) }
                }
                .help(showsNumber ? "Which accounts the number and the warning icon count"
                                  : "Which accounts the warning icon counts")
                Picker("Period", selection: setting(\.menuBarPeriod)) {
                    ForEach(MenuBarPeriod.allCases, id: \.self) { Text(Fmt.periodTitle($0)).tag($0) }
                }
                .disabled(!tokenOptions)
                Toggle("Include cache tokens", isOn: setting(\.menuBarIncludesCache))
                    .disabled(!tokenOptions)
            } header: {
                Text("Menu bar")
            } footer: {
                SettingsMenuBarPreview()
            }

            Section("Refresh") {
                Picker("Refresh every", selection: setting(\.refreshIntervalSeconds)) {
                    ForEach(SettingsRules.refreshChoices(current: model.settings.refreshIntervalSeconds), id: \.self) {
                        Text(SettingsRules.refreshTitle($0)).tag($0)
                    }
                }
            }

            Section {
                Toggle("Check quota online", isOn: setting(\.onlineQuotaEnabled))
            } header: {
                Text("Online quota")
            } footer: {
                SettingsFooter("TokenBar uses the sign-in each CLI already saved to ask Anthropic, OpenAI and Google for your quota, and asks muse.ai for Muse accounts you signed in to here, at most every 5 minutes. When off, TokenBar makes no network requests and only counts local logs. You can also turn it off per account.")
            }
        }
        .formStyle(.grouped)
    }
}

/// The menu bar label as it looks with the current settings.
private struct SettingsMenuBarPreview: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Preview")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Image(systemName: model.menuBarSymbol)
                if model.settings.menuBarShowsNumber {
                    Text(model.menuBarTitle).monospacedDigit()
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.08)))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Menu bar preview: \(model.settings.menuBarShowsNumber ? model.menuBarTitle : "icon only")")
            Text("The icon turns into a warning when a quota reaches 90%.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SettingsFooter.inset)
    }
}
