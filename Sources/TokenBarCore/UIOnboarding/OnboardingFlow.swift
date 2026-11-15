import Foundation

/// The pages of the first-launch setup window, in order.
public enum OnboardingPage: Int, CaseIterable, Sendable {
    case welcome
    case accounts
    case alerts

    public var next: OnboardingPage? { OnboardingPage(rawValue: rawValue + 1) }
    public var previous: OnboardingPage? { OnboardingPage(rawValue: rawValue - 1) }
    public var isFirst: Bool { previous == nil }
    public var isLast: Bool { next == nil }

    /// Title of the default button: "Continue" on every page but the last, which says "Done".
    public var primaryButtonTitle: String { isLast ? "Done" : "Continue" }

    /// Short name for accessibility (page dots).
    public var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .accounts: return "Your accounts"
        case .alerts: return "Quota and notifications"
        }
    }
}

/// What the accounts page shows for one provider's "Sign in" control.
public enum OnboardingSignInState: Equatable, Sendable {
    /// A "Sign in…" button.
    case available
    /// No button; the reason is shown as a caption (or a help tag next to a provider with accounts).
    case unavailable(reason: String)
    /// A CLI sign-in is running: spinner, the hint and Cancel.
    case inProgress(hint: String?)
    /// The provider's web sign-in window is open.
    case waitingForWeb
    /// The last attempt failed: the message and Try again.
    case failed(message: String)
    /// The last attempt worked; the new account appears after the next scan.
    case succeeded

    /// - Parameters:
    ///   - webSignInMessage: the last web sign-in error, shown like a failed CLI sign-in.
    ///   - accountRegistered: whether the account a successful CLI sign-in added is already listed; the
    ///     "Signed in" row then gives way to the account itself.
    public static func make(signIn: SignInKind, unavailableReason: String?, phase: LoginPhase?,
                            isWebSignInOpen: Bool, webSignInMessage: String? = nil,
                            accountRegistered: Bool = false) -> OnboardingSignInState {
        if let unavailableReason { return .unavailable(reason: unavailableReason) }
        switch signIn {
        case .none:
            return .unavailable(reason: "Signing in from TokenBar is not available for this provider.")
        case .web:
            if isWebSignInOpen { return .waitingForWeb }
            if let webSignInMessage { return .failed(message: webSignInMessage) }
            return .available
        case .cli:
            switch phase {
            case nil, .cancelled?: return .available
            case .locatingCLI?: return .inProgress(hint: nil)
            case .waitingForUser(let hint)?: return .inProgress(hint: hint)
            case .failed(let message)?: return .failed(message: message)
            case .succeeded?: return accountRegistered ? .available : .succeeded
            }
        }
    }

    /// Whether one of `dataPaths` lies in the managed home a sign-in reported. Compared by the home's
    /// own folder name, so a path spelled with "~" or with the provider's suffix still matches.
    public static func isRegistered(homePath: String, dataPaths: [String]) -> Bool {
        let folder = (homePath as NSString).lastPathComponent
        guard !folder.isEmpty, folder != "/" else { return false }
        return dataPaths.contains { ($0 as NSString).pathComponents.contains(folder) }
    }

    /// Providers whose CLI sign-in is still running, to cancel when the setup window closes.
    public static func runningProviders(_ phases: [String: LoginPhase]) -> [String] {
        phases.compactMap { id, phase in
            switch phase {
            case .locatingCLI, .waitingForUser: return id
            case .succeeded, .failed, .cancelled: return nil
            }
        }.sorted()
    }

    /// Why there is no "Sign in…" button, for a caption under the provider; nil otherwise.
    public var unavailableReason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }

    /// Whether the "Sign in…" button is shown next to the provider's name (a failed attempt offers
    /// Try again in its own row instead).
    public var showsButton: Bool {
        switch self {
        case .available, .succeeded: return true
        case .unavailable, .inProgress, .waitingForWeb, .failed: return false
        }
    }
}

/// One account line on the accounts page.
public struct OnboardingAccountRow: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    /// Plan, organization and the email when it differs from the title; nil when nothing is known.
    public let subtitle: String?
    public let isEnabled: Bool

    public init(id: UUID, title: String, subtitle: String?, isEnabled: Bool) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.isEnabled = isEnabled
    }
}

/// One provider section on the accounts page.
public struct OnboardingProviderGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let symbolName: String
    public let accounts: [OnboardingAccountRow]
    public let signIn: OnboardingSignInState

    public init(id: String, displayName: String, symbolName: String, accounts: [OnboardingAccountRow],
                signIn: OnboardingSignInState) {
        self.id = id
        self.displayName = displayName
        self.symbolName = symbolName
        self.accounts = accounts
        self.signIn = signIn
    }
}

/// The accounts page as a whole.
public enum OnboardingAccountsStatus: Equatable, Sendable {
    /// The first scan is running and nothing has been found yet.
    case searching
    /// Accounts were found; `stillScanning` is true while a scan is running.
    case found(count: Int, stillScanning: Bool)
    /// The scan finished and found nothing.
    case empty

    public var headline: String {
        switch self {
        case .searching:
            return "Looking for accounts on this Mac…"
        case .found(let count, _):
            let accounts = count == 1 ? "1 account" : "\(count) accounts"
            return "TokenBar found \(accounts). Sign in to add another, or turn any off later in Settings."
        case .empty:
            return "No accounts found yet. Sign in below, or use one of these tools once and TokenBar picks it up."
        }
    }

    public var isScanning: Bool {
        switch self {
        case .searching: return true
        case .found(_, let stillScanning): return stillScanning
        case .empty: return false
        }
    }
}

public enum OnboardingAccounts {
    /// One group per provider, in catalog order, with or without accounts: a provider without accounts
    /// shows either a way to sign in or why that is not possible.
    public static func groups(catalog: ProviderCatalog, accounts: [Account], identities: [UUID: AccountIdentity],
                              signInState: (ProviderInfo) -> OnboardingSignInState) -> [OnboardingProviderGroup] {
        catalog.providers.map { info in
            let rows = accounts.filter { $0.providerID == info.id }.map { account in
                OnboardingAccountRow(id: account.id, title: account.name,
                                     subtitle: subtitle(for: account, identity: identities[account.id]),
                                     isEnabled: account.isEnabled)
            }
            let state = signInState(info)
            return OnboardingProviderGroup(id: info.id, displayName: info.displayName, symbolName: info.symbolName,
                                           accounts: rows, signIn: state)
        }
    }

    /// Providers with accounts (one section each) and providers without any (one row each in a shared
    /// section), both in the original order.
    public static func split(_ groups: [OnboardingProviderGroup]) -> (found: [OnboardingProviderGroup], notFound: [OnboardingProviderGroup]) {
        (groups.filter { !$0.accounts.isEmpty }, groups.filter { $0.accounts.isEmpty })
    }

    /// Header of the shared section of providers without accounts: none when nothing was found at all,
    /// and no claim that a tool is missing while detection is still running.
    public static func notFoundHeader(foundAny: Bool, isScanning: Bool) -> String? {
        guard foundAny else { return nil }
        return isScanning ? "Other tools" : "Not found on this Mac"
    }

    /// "Max · Example Labs", with the email first when the account's name is something else.
    public static func subtitle(for account: Account, identity: AccountIdentity?) -> String? {
        var parts: [String] = []
        if let identity {
            if let email = identity.email, email.caseInsensitiveCompare(account.name) != .orderedSame { parts.append(email) }
            if let plan = identity.planLabel { parts.append(plan) }
            if let organization = identity.organization { parts.append(organization) }
        }
        if !account.isEnabled { parts.append("Turned off") }
        if parts.isEmpty, identity?.isSignedIn == true { return "Signed in" }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public static func status(accountCount: Int, isScanning: Bool, hasScanned: Bool) -> OnboardingAccountsStatus {
        if accountCount > 0 { return .found(count: accountCount, stillScanning: isScanning) }
        return (isScanning || !hasScanned) ? .searching : .empty
    }
}

/// The notification choice on the last page.
public enum OnboardingAlerts {
    /// The threshold to store when the switch changes. Turning on brings back the last choice (or the
    /// default when that is not one of the offered values); turning off stores nil.
    public static func threshold(enabled: Bool, remembered: Int?) -> Int? {
        guard enabled else { return nil }
        if let remembered, AppSettings.quotaAlertThresholdChoices.contains(remembered) { return remembered }
        return AppSettings.defaultQuotaAlertThreshold
    }

    /// Whether to ask for notification permission as the setup closes: notifications are on (the
    /// default) and macOS has not asked yet, so accepting the default still leads to working alerts.
    public static func shouldRequestPermission(threshold: Int?, permissionNotDetermined: Bool) -> Bool {
        threshold != nil && permissionNotDetermined
    }
}

/// A failed sign-in message split into its sentence and a shell command, so the command can be shown
/// on its own line, unbroken and easy to copy.
public struct OnboardingProblemText: Equatable, Sendable {
    public let text: String
    public let command: String?

    public init(text: String, command: String?) {
        self.text = text
        self.command = command
    }

    /// The command follows "Install it with:" (see `LoginProviderSpec.notInstalledMessage`).
    public static func parse(_ message: String) -> OnboardingProblemText {
        let marker = "Install it with:"
        guard let range = message.range(of: marker) else { return OnboardingProblemText(text: message, command: nil) }
        let command = message[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return OnboardingProblemText(text: message, command: nil) }
        let text = message[..<range.lowerBound].trimmingCharacters(in: .whitespaces) + " Install it with this command in Terminal:"
        return OnboardingProblemText(text: text, command: command)
    }
}
