import SwiftUI
import AppKit
import TokenBarCore

/// Hosts SettingsView in a plain NSWindow. This avoids the `Settings` scene, which is
/// unreliable to open from an accessory (no Dock icon) app on macOS 13/14.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(model: AppModel) {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(model))
            let w = NSWindow(contentViewController: host)
            w.title = "TokenBar Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            AccountsTab().tabItem { Label("Accounts", systemImage: "person.2") }
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 640, height: 580)
        .padding()
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Accounts

struct AccountsTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("TokenBar finds accounts on this Mac automatically, including profiles set up in your shell.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if model.isScanning { ProgressView().controlSize(.small) }
                Button("Rescan") { Task { await model.rescan() } }
                    .disabled(model.isScanning)
                    .help("Look for new accounts now")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.accounts.isEmpty && model.hasScanned {
                        NoAccountsView()
                        Divider()
                    }
                    ForEach(model.registry.providers, id: \.id) { provider in
                        ProviderAccounts(provider: provider)
                        Divider()
                    }
                }
                .padding(6)
            }
        }
    }
}

/// First run with nothing found: offer sign-in, not a folder field.
struct NoAccountsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("No accounts found yet", systemImage: "person.crop.circle.badge.questionmark")
                .font(.headline)
            Text("If you use Claude Code, Codex or Gemini CLI, sign in below and TokenBar adds the account. Accounts you use from the terminal appear here on their own after you run the CLI once.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.opacity(0.08)))
    }
}

struct ProviderAccounts: View {
    @EnvironmentObject var model: AppModel
    let provider: any UsageProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(provider.displayName, systemImage: provider.symbolName)
                .font(.headline)
            let accounts = model.accounts(for: provider.id)
            if accounts.isEmpty {
                Text("No accounts found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(accounts) { account in
                AccountRow(account: account, provider: provider)
            }
            SignInRow(provider: provider)
            AdvancedAddFolder(provider: provider)
        }
    }
}

// MARK: Account row

struct StatusDot: View {
    let health: AccountHealth

    private var color: Color {
        switch health {
        case .ok: return .green
        case .warning: return .orange
        case .error: return .red
        case .disabled, .unknown: return .gray
        }
    }

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
}

@MainActor
struct AccountRow: View {
    @EnvironmentObject var model: AppModel
    let account: Account
    let provider: any UsageProvider

    @State private var confirmDelete = false
    @State private var copiedAlias = false

    var body: some View {
        let status = model.health(of: account)
        let health = status.0
        let healthText = status.1
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusDot(health: health)
                    .help(healthText)
                    .accessibilityLabel("Status: \(healthText)")
                TextField("Name", text: Binding(
                    get: { account.name },
                    set: { model.rename(account.id, to: $0) }))
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                    .frame(maxWidth: 240)
                SourceBadge(origin: account.origin ?? .manual)
                Spacer()
                Toggle("Enabled", isOn: Binding(
                    get: { account.isEnabled },
                    set: { model.setEnabled(account.id, $0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .help(account.isEnabled ? "Turn off to hide this account" : "Turn on to show this account")
                moreMenu
            }
            if let line = Fmt.identityLine(model.identities[account.id]) {
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
            Text(Fmt.shortPath(account.dataPath))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(account.dataPath)
            if health == .warning || health == .error {
                Text(healthText).font(.caption).foregroundStyle(.orange)
            }
            if account.isEnabled && model.backendSupportsOnlineQuota(provider.id) {
                Toggle("Online quota", isOn: Binding(
                    get: { account.onlineQuotaEnabled },
                    set: { model.setOnlineQuota(account.id, enabled: $0) }))
                    .font(.caption)
            }
            if copiedAlias {
                Text("Alias copied. Paste it into your shell profile to use this account in the terminal.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        .opacity(account.isEnabled ? 1 : 0.6)
        .confirmationDialog("Remove \u{201C}\(account.name)\u{201D}?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { model.removeAccount(account.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            if account.origin == .signedIn {
                Text("This also deletes the sign-in TokenBar created for this account. Your other CLI profiles are not touched.")
            } else {
                Text("TokenBar will stop showing it and will not add it back automatically. No files are deleted.")
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            if let alias = model.shellAlias(for: account) {
                Button("Copy shell alias") {
                    Clipboard.copy(alias)
                    copiedAlias = true
                }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: expandPath(account.dataPath))])
            }
            if account.origin == .manual || account.origin == nil {
                Button("Change folder…") { chooseFolder() }
            }
            Divider()
            Button("Remove…", role: .destructive) { confirmDelete = true }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("More actions for \(account.name)")
    }

    private func chooseFolder() {
        guard let url = FolderPicker.choose() else { return }
        model.setDataPath(account.id, to: url.path)
    }
}

struct SourceBadge: View {
    let origin: AccountOrigin

    var body: some View {
        Text(origin.label)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .foregroundStyle(.secondary)
    }
}

enum FolderPicker {
    @MainActor
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

// MARK: Sign in

struct SignInRow: View {
    @EnvironmentObject var model: AppModel
    let provider: any UsageProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let reason = model.signInUnavailableReason(provider.id) {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            } else {
                let phase = model.signInPhases[provider.id]
                switch phase {
                case .locatingCLI?:
                    progress("Looking for the \(provider.displayName) command…")
                case .waitingForUser(let hint)?:
                    progress(hint)
                default:
                    HStack(spacing: 8) {
                        Button {
                            model.startSignIn(provider.id)
                        } label: {
                            Label("Sign in to another account", systemImage: "person.badge.plus")
                        }
                        result(phase)
                    }
                }
                Text("An account added this way shows its quota. Token counts include only usage made through this profile.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Cancel") { model.cancelSignIn(provider.id) }
        }
    }

    @ViewBuilder
    private func result(_ phase: LoginPhase?) -> some View {
        switch phase {
        case .succeeded?:
            Label("Signed in. The account was added.", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
            Button("OK") { model.dismissSignIn(provider.id) }.buttonStyle(.borderless).font(.caption)
        case .failed(let message)?:
            Text(message).font(.caption).foregroundStyle(.orange)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button("Dismiss") { model.dismissSignIn(provider.id) }.buttonStyle(.borderless).font(.caption)
        default:
            EmptyView()
        }
    }
}

// MARK: Advanced: add a folder by hand

struct AdvancedAddFolder: View {
    @EnvironmentObject var model: AppModel
    let provider: any UsageProvider

    @State private var expanded = false
    @State private var path = ""
    @State private var validation: PathValidation?

    var body: some View {
        DisclosureGroup("Advanced", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text(provider.dataPathHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField("Folder", text: $path)
                        .onSubmit { add() }
                    Button("Choose…") {
                        if let url = FolderPicker.choose() {
                            path = url.path
                            add()
                        }
                    }
                    Button("Add") { add() }.disabled(path.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let validation {
                    Label(validation.message, systemImage: validation.isValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(validation.isValid ? Color.green : Color.orange)
                }
            }
            .padding(.top, 4)
        }
        .font(.caption)
    }

    private func add() {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let result = model.addManualAccount(providerID: provider.id, path: trimmed)
        validation = result
        if result.isValid { path = "" }
    }
}

// MARK: - General

struct GeneralTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Open at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }))
                if model.launchAtLoginNeedsApproval {
                    Text("Allow TokenBar in System Settings > General > Login Items.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Refresh") {
                Picker("Refresh every", selection: Binding(
                    get: { model.settings.refreshIntervalSeconds },
                    set: { v in model.updateSettings { $0.refreshIntervalSeconds = v } })) {
                    Text("15 seconds").tag(15)
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                }
            }
            Section("Menu bar") {
                Picker("Show", selection: Binding(
                    get: { model.settings.menuBarProviderID ?? "" },
                    set: { v in model.updateSettings { $0.menuBarProviderID = v.isEmpty ? nil : v } })) {
                    Text("All providers").tag("")
                    ForEach(model.registry.providers, id: \.id) { Text($0.displayName).tag($0.id) }
                }
                Picker("Period", selection: Binding(
                    get: { model.settings.menuBarPeriod },
                    set: { v in model.updateSettings { $0.menuBarPeriod = v } })) {
                    ForEach(MenuBarPeriod.allCases, id: \.self) { Text(Fmt.periodTitle($0)).tag($0) }
                }
                Toggle("Show number next to the icon", isOn: Binding(
                    get: { model.settings.menuBarShowsNumber },
                    set: { v in model.updateSettings { $0.menuBarShowsNumber = v } }))
                Toggle("Include cache tokens", isOn: Binding(
                    get: { model.settings.menuBarIncludesCache },
                    set: { v in model.updateSettings { $0.menuBarIncludesCache = v } }))
                Text("Now showing: \(model.menuBarTitle). The icon turns into a warning when any quota is above 90%.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Online quota") {
                Toggle("Check quota online", isOn: Binding(
                    get: { model.settings.onlineQuotaEnabled },
                    set: { v in model.updateSettings { $0.onlineQuotaEnabled = v } }))
                Text("When on, TokenBar reads the sign-in each CLI already saved and asks OpenAI, Anthropic and Google for your quota, at most every 5 minutes. When off, TokenBar makes no network requests and only counts local logs. You can also turn it off per account.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}
