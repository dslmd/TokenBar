import SwiftUI
import AppKit
import TokenBarCore

/// One account: status dot, name and subtitle, a switch and the `…` menu. Problems show under it.
struct SettingsAccountRow: View {
    @EnvironmentObject var model: AppModel
    let account: Account
    let provider: ProviderInfo
    var isHighlighted = false

    @State private var confirmRemove = false
    @State private var renaming = false
    @State private var copiedAlias = false

    private var caps: ProviderCapabilities { provider.capabilities }
    private var isWeb: Bool { caps.signIn == .web }

    var body: some View {
        let (health, healthText) = model.health(of: account)
        let problem = model.attentionMessage(for: account)
        HStack(alignment: .center, spacing: 10) {
            StatusDot(health: health)
                .help(healthText)
                .accessibilityLabel("Status: \(healthText)")
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let problem {
                    SettingsProblemText(text: problem)
                        .padding(.top, 1)
                }
                if copiedAlias {
                    Text("Alias copied. Paste it into your shell profile to use this account in the terminal.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .opacity(account.isEnabled ? 1 : 0.55)
            .help(SettingsRules.accountHelp(origin: account.origin, path: caps.folderAccounts ? account.dataPath : nil,
                                            home: NSHomeDirectory()))
            Spacer(minLength: 8)
            Toggle("Show this account", isOn: Binding(
                get: { account.isEnabled },
                set: { model.setEnabled(account.id, $0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .help(account.isEnabled ? "Turn off to hide this account" : "Turn on to show this account")
            moreMenu
        }
        .padding(.vertical, 2)
        .background(highlight)
        .animation(.easeInOut(duration: 0.2), value: isHighlighted)
        .sheet(isPresented: $renaming) {
            SettingsRenameSheet(currentName: account.name) { newName in
                if let newName { model.rename(account.id, to: newName) }
                renaming = false
            }
        }
        .confirmationDialog("Remove \u{201C}\(account.name)\u{201D}?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { model.removeAccount(account.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            if isWeb {
                Text("This deletes the muse.ai session TokenBar saved in the Keychain. Your Muse account itself is not changed.")
            } else if account.origin == .signedIn {
                Text("This also deletes the sign-in TokenBar created for this account. Your other CLI profiles are not touched.")
            } else {
                Text("TokenBar will stop showing it and will not add it back automatically. No files are deleted.")
            }
        }
    }

    private var subtitle: String? {
        SettingsRules.accountSubtitle(name: account.name, identity: model.identities[account.id],
                                      webPlan: model.webQuota[account.id]?.usage?.planName,
                                      origin: account.origin)
    }

    private var highlight: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.accentColor.opacity(isHighlighted ? 0.18 : 0))
            .padding(.horizontal, -8)
            .padding(.vertical, -4)
    }

    private var moreMenu: some View {
        SettingsMoreMenu(accessibilityLabel: "More actions for \(account.name)") {
            Button("Rename…") { renaming = true }
            if caps.hasOnlineQuota {
                let globalOn = model.settings.onlineQuotaEnabled
                Toggle(globalOn ? "Online quota" : "Online quota (off in General)", isOn: Binding(
                    get: { account.onlineQuotaEnabled },
                    set: { model.setOnlineQuota(account.id, enabled: $0) }))
                    .disabled(!globalOn)
            }
            if let alias = model.shellAlias(for: account) {
                Divider()
                Button("Copy shell alias") {
                    Clipboard.copy(alias)
                    copiedAlias = true
                }
            }
            if caps.folderAccounts {
                Divider()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: expandPath(account.dataPath))])
                }
                if account.origin == .manual || account.origin == nil {
                    Button("Change folder…") { chooseFolder() }
                }
                Text(Fmt.shortPath(account.dataPath))
            }
            if isWeb {
                Divider()
                Button("Sign in again…") { model.signInToMuse(replacing: account.id) }
                    .disabled(model.isSigningInToMuse)
            } else if caps.signIn == .cli && account.origin == .signedIn {
                Divider()
                // Adds a fresh sign-in; the expired profile can then be removed.
                Button("Sign in again…") { model.startSignIn(provider.id) }
                    .disabled(model.isSigningIn(provider.id) || model.signInUnavailableReason(provider.id) != nil)
            }
            Divider()
            Button("Remove…", role: .destructive) { confirmRemove = true }
        }
    }

    private func chooseFolder() {
        guard let url = FolderPicker.choose() else { return }
        model.setDataPath(account.id, to: url.path)
    }
}

/// A small sheet for a new account name. Calls `done` with the new name, or nil when cancelled.
struct SettingsRenameSheet: View {
    let currentName: String
    let done: (String?) -> Void

    @State private var name: String

    init(currentName: String, done: @escaping (String?) -> Void) {
        self.currentName = currentName
        self.done = done
        _name = State(initialValue: currentName)
    }

    private var validName: String? { SettingsRules.validatedName(name, current: currentName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename account")
                .font(.headline)
            Text("The name is shown in the menu bar window and in notifications.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if let validName { done(validName) } }
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { done(validName) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(validName == nil)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 360)
    }
}
