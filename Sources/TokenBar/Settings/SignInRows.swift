import SwiftUI
import TokenBarCore

/// Last row of a CLI provider's section: "Sign in to another account…", with the sign-in's progress,
/// failure or success in place of the button.
struct SettingsSignInRow: View {
    @EnvironmentObject var model: AppModel
    let provider: ProviderInfo
    /// Opens the add-folder sheet; offered in place of sign-in when sign-in is not available.
    var addFolder: (() -> Void)?

    var body: some View {
        if let reason = model.signInUnavailableReason(provider.id) {
            if provider.capabilities.folderAccounts, let addFolder {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Button("Add folder manually…", action: addFolder)
                            .help(provider.dataPathHint ?? "Choose the folder where the CLI keeps its data.")
                        Spacer()
                    }
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            let phase = model.signInPhases[provider.id]
            switch phase {
            case .locatingCLI?:
                SettingsSignInProgress(text: "Looking for the \(provider.displayName) command…") { model.cancelSignIn(provider.id) }
            case .waitingForUser(let hint)?:
                SettingsSignInProgress(text: hint) { model.cancelSignIn(provider.id) }
            case .failed(let message)?:
                SettingsSignInFailure(text: SettingsRules.signInFailureText(message),
                                      dismiss: { model.dismissSignIn(provider.id) },
                                      retry: { model.startSignIn(provider.id) })
            case .succeeded?:
                HStack(spacing: 8) {
                    Label("Signed in. The account was added.", systemImage: "checkmark.circle.fill")
                        .labelStyle(SettingsLabelStyle())
                        .symbolRenderingMode(.multicolor)
                        .font(.callout)
                    Spacer()
                    Button("OK") { model.dismissSignIn(provider.id) }
                }
            default:
                HStack {
                    Button(model.accounts(for: provider.id).isEmpty ? "Sign in to \(provider.displayName)…"
                                                                     : "Sign in to another account…") {
                        model.startSignIn(provider.id)
                    }
                        .help("An account added this way shows its quota. Token counts include only usage made through this profile.")
                    Spacer()
                }
            }
        }
    }
}

/// A failed sign-in: the sentence with Dismiss and Try again, and the command to copy on its own line.
private struct SettingsSignInFailure: View {
    let text: SettingsRules.SignInFailureText
    let dismiss: () -> Void
    let retry: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label {
                    Text(text.sentence)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .labelStyle(SettingsLabelStyle())
                .font(.callout)
                Spacer(minLength: 8)
                Button("Dismiss", action: dismiss)
                    .buttonStyle(.borderless)
                Button("Try again", action: retry)
            }
            if let command = text.command {
                HStack(spacing: 8) {
                    Text(command)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.06)))
                    Button(copied ? "Copied" : "Copy") {
                        Clipboard.copy(command)
                        copied = true
                    }
                    .buttonStyle(.borderless)
                    .help("Copy the command")
                    Spacer(minLength: 0)
                }
                .padding(.leading, 18)
            }
        }
    }
}

/// Sign-in for providers that use an in-app web window (Muse). Always available: no CLI is needed.
struct SettingsWebSignInRow: View {
    @EnvironmentObject var model: AppModel
    let provider: ProviderInfo

    var body: some View {
        if model.isSigningInToMuse {
            SettingsSignInProgress(text: model.museSignInAccountID == nil
                           ? "Finish signing in in the \(provider.displayName) window."
                           : "Sign in again in the \(provider.displayName) window.") { model.cancelMuseSignIn() }
        } else {
            HStack {
                Button(model.accounts(for: provider.id).isEmpty ? "Sign in to \(provider.displayName)…"
                                                                 : "Sign in to another account…") {
                    model.startSignIn(provider.id)
                }
                .help("Each account signs in in its own window. The session is kept in your Keychain.")
                Spacer()
            }
        }
        if let message = model.webSignInMessage {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                SettingsProblemText(text: message)
                Spacer(minLength: 8)
                Button("Dismiss") { model.dismissWebSignInMessage() }
                    .buttonStyle(.borderless)
            }
        }
    }
}

/// Spinner, the hint of what to do next, and Cancel.
struct SettingsSignInProgress: View {
    let text: String
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Cancel", action: cancel)
        }
    }
}

/// Sheet for adding a profile folder by hand (from the section's `…` menu).
struct SettingsAddFolderSheet: View {
    @EnvironmentObject var model: AppModel
    let provider: ProviderInfo
    let done: () -> Void

    @State private var path = ""
    @State private var validation: PathValidation?

    private var trimmed: String { path.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a \(provider.displayName) folder")
                .font(.headline)
            Text(provider.dataPathHint ?? "Choose the folder where the CLI keeps its data.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("Folder", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Choose…") {
                    if let url = FolderPicker.choose() { path = url.path }
                }
            }
            if let validation, !validation.isValid {
                SettingsProblemText(text: validation.message)
            }
            HStack {
                Spacer()
                Button("Cancel", action: done)
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 440)
    }

    private func add() {
        guard !trimmed.isEmpty else { return }
        let result = model.addManualAccount(providerID: provider.id, path: trimmed)
        validation = result
        if result.isValid { done() }
    }
}
