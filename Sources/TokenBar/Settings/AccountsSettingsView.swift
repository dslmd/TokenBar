import SwiftUI
import AppKit
import TokenBarCore

/// Accounts tab: the scan header, then one section per provider with its accounts and a sign-in row.
struct AccountsSettingsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var navigation: SettingsNavigation

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                SettingsScanHeader()
                ForEach(model.catalog.providers) { provider in
                    SettingsProviderSection(provider: provider, highlightedAccountID: navigation.highlightedAccountID)
                }
            }
            .formStyle(.grouped)
            .onReceive(navigation.$scrollRequest.compactMap { $0 }) { request in
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(request.id, anchor: .center) }
            }
        }
    }
}

/// "TokenBar finds accounts on this Mac automatically." with Rescan.
private struct SettingsScanHeader: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Section {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "magnifyingglass.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("TokenBar finds accounts on this Mac automatically.")
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if model.isScanning {
                    ProgressView().controlSize(.small)
                }
                Button("Rescan") { Task { await model.rescan() } }
                    .disabled(model.isScanning)
                    .help("Look for new accounts now")
            }
            .padding(.vertical, 2)
        }
    }

    private var subtitle: String {
        if model.isScanning { return "Looking for accounts…" }
        if model.accounts.isEmpty && model.hasScanned {
            return "None found yet. Sign in below, or use a CLI once and rescan."
        }
        return "Profiles set up in your shell are included."
    }
}

private struct SettingsProviderSection: View {
    @EnvironmentObject var model: AppModel
    let provider: ProviderInfo
    let highlightedAccountID: UUID?

    @State private var addingFolder = false

    /// A sign-in button, or "Add folder manually…" in its place, ends the section.
    private var hasAddButton: Bool {
        model.signInUnavailableReason(provider.id) == nil || provider.capabilities.folderAccounts
    }

    var body: some View {
        let accounts = model.accounts(for: provider.id)
        Section {
            if SettingsRules.showsNoAccountsRow(accountCount: accounts.count, hasScanned: model.hasScanned,
                                                isScanning: model.isScanning, hasAddButton: hasAddButton) {
                Text("No accounts yet")
                    .foregroundStyle(.secondary)
            }
            ForEach(accounts) { account in
                SettingsAccountRow(account: account, provider: provider, isHighlighted: highlightedAccountID == account.id)
                    .id(account.id)
            }
            switch provider.capabilities.signIn {
            case .web: SettingsWebSignInRow(provider: provider)
            case .cli, .none: SettingsSignInRow(provider: provider) { addingFolder = true }
            }
        } header: {
            HStack(spacing: 6) {
                Label(provider.displayName, systemImage: provider.symbolName)
                Spacer()
                if provider.capabilities.folderAccounts {
                    SettingsMoreMenu(accessibilityLabel: "More actions for \(provider.displayName)") {
                        Button("Add folder manually…") { addingFolder = true }
                    }
                }
            }
        } footer: {
            if let note = provider.note {
                SettingsFooter(note)
            }
        }
        .sheet(isPresented: $addingFolder) {
            SettingsAddFolderSheet(provider: provider) { addingFolder = false }
                .environmentObject(model)
        }
    }
}
