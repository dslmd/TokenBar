import SwiftUI
import AppKit
import TokenBarCore

/// Page 2: what detection found, live, with a way to sign in to more accounts.
struct OnboardingAccountsPage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let status = model.onboardingStatus
        VStack(spacing: 0) {
            OnboardingPageHeader(title: "Your accounts", subtitle: status.headline,
                                 showsSpinner: status.isScanning && status != .searching)
            if status == .searching {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("This takes a few seconds.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let split = OnboardingAccounts.split(model.onboardingGroups)
                Divider()
                    .padding(.top, 12)
                Form {
                    ForEach(split.found) { group in
                        OnboardingProviderSection(group: group)
                    }
                    if !split.notFound.isEmpty {
                        Section {
                            ForEach(split.notFound) { group in
                                OnboardingProviderLine(group: group)
                                OnboardingSignInStatusRows(group: group)
                            }
                        } header: {
                            if let header = OnboardingAccounts.notFoundHeader(foundAny: !split.found.isEmpty,
                                                                              isScanning: status.isScanning) {
                                Text(header)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                // The list scrolls under the header otherwise.
                .clipped()
            }
        }
    }
}

/// A provider with accounts: its accounts, then sign-in progress. "Sign in…" sits in the header.
struct OnboardingProviderSection: View {
    let group: OnboardingProviderGroup

    var body: some View {
        Section {
            ForEach(group.accounts) { row in
                OnboardingAccountLine(row: row)
            }
            OnboardingSignInStatusRows(group: group)
        } header: {
            HStack(spacing: 6) {
                OnboardingProviderSymbol(name: group.symbolName)
                Text(group.displayName)
                Spacer()
                OnboardingSignInButton(group: group)
            }
        }
    }
}

/// A provider without accounts, as one row: symbol, name and "Sign in…" (or why there is none).
struct OnboardingProviderLine: View {
    let group: OnboardingProviderGroup

    var body: some View {
        HStack(spacing: 8) {
            OnboardingProviderSymbol(name: group.symbolName)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.displayName)
                if let reason = group.signIn.unavailableReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            OnboardingSignInButton(group: group)
        }
        .accessibilityElement(children: .contain)
    }
}

struct OnboardingProviderSymbol: View {
    let name: String

    var body: some View {
        Image(systemName: name)
            .foregroundStyle(.secondary)
            .frame(width: 18)
            .accessibilityHidden(true)
    }
}

struct OnboardingSignInButton: View {
    @EnvironmentObject var model: AppModel
    let group: OnboardingProviderGroup

    var body: some View {
        if group.signIn.showsButton {
            Button("Sign in…") { model.startOnboardingSignIn(group.id) }
                .controlSize(.small)
                .help(group.accounts.isEmpty ? "Sign in to \(group.displayName)"
                                             : "Sign in to another \(group.displayName) account")
        } else if !group.accounts.isEmpty, let reason = group.signIn.unavailableReason {
            // A provider without accounts shows the reason as a caption instead.
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .help(reason)
                .accessibilityLabel(reason)
        }
    }
}

/// Sign-in progress or its outcome, as rows under the provider.
struct OnboardingSignInStatusRows: View {
    @EnvironmentObject var model: AppModel
    let group: OnboardingProviderGroup

    var body: some View {
        switch group.signIn {
        case .inProgress(let hint):
            OnboardingProgressLine(text: hint ?? "Starting sign-in…") { model.cancelSignIn(group.id) }
        case .waitingForWeb:
            OnboardingProgressLine(text: "Sign in to muse.ai in the window that opened.") { model.cancelMuseSignIn() }
        case .failed(let message):
            OnboardingProblemLine(problem: OnboardingProblemText.parse(message), actionTitle: "Try again") {
                model.startOnboardingSignIn(group.id)
            }
        case .succeeded:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text("Signed in. The account appears here in a moment.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .available, .unavailable:
            EmptyView()
        }
    }
}

struct OnboardingAccountLine: View {
    let row: OnboardingAccountRow

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(row.isEnabled ? .primary : .secondary)
                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if row.isEnabled {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Found")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Spinner, the sign-in hint and Cancel.
struct OnboardingProgressLine: View {
    let text: String
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Cancel", action: cancel)
                .controlSize(.small)
        }
    }
}

/// An orange warning with one action, e.g. a failed sign-in and Try again. A shell command in the
/// message gets its own line, never wrapped, with a Copy button.
struct OnboardingProblemLine: View {
    let problem: OnboardingProblemText
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(problem.text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
            if let command = problem.command {
                OnboardingCommandLine(command: command)
                    .padding(.leading, 26)
            }
        }
    }
}

/// A shell command in a monospaced well, selectable, with a Copy button.
struct OnboardingCommandLine: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 6) {
            Text(command)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.06)))
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .help(copied ? "Copied" : "Copy command")
            .accessibilityLabel("Copy command")
        }
    }
}
