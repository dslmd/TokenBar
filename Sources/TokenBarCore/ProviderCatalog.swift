import Foundation

/// How accounts of a provider are added by signing in.
public enum SignInKind: Equatable, Sendable {
    /// No sign-in from TokenBar (accounts are only detected or added as folders).
    case none
    /// The official CLI signs in inside a TokenBar-managed home (`AccountLoginDriving`).
    case cli
    /// TokenBar shows the provider's website in its own window and keeps the session cookies in the Keychain.
    case web
}

/// Where online quota comes from, if anywhere.
public enum OnlineQuotaSource: Equatable, Sendable {
    case none
    /// The sign-in the CLI saved in its home (`QuotaService`).
    case cliCredentials
    /// A website session signed in inside TokenBar (`MuseAIService`).
    case webSession
}

/// What a provider supports. Views switch on this instead of on provider ids.
public struct ProviderCapabilities: Equatable, Sendable {
    /// Token counts come from local logs (token grid, 7-day chart, "today" figures, menu bar number).
    public var localLogs: Bool
    /// Accounts are folders: automatic detection, path validation, folder picker, "Show in Finder", shell alias.
    public var folderAccounts: Bool
    public var signIn: SignInKind
    public var onlineQuota: OnlineQuotaSource

    public init(localLogs: Bool, folderAccounts: Bool, signIn: SignInKind, onlineQuota: OnlineQuotaSource) {
        self.localLogs = localLogs
        self.folderAccounts = folderAccounts
        self.signIn = signIn
        self.onlineQuota = onlineQuota
    }

    public var hasOnlineQuota: Bool { onlineQuota != .none }
}

/// One provider as the app lists it. Log-based providers wrap their `UsageProvider`; others have none.
public struct ProviderInfo: Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let symbolName: String
    public let capabilities: ProviderCapabilities
    /// The log parser, for providers with `localLogs`.
    public let usageProvider: (any UsageProvider)?
    /// One short line shown under the provider's header in settings (nil: none).
    public let note: String?
    /// Shown instead of a sign-in button when `signIn` is `.none`.
    public let signInUnavailableText: String?

    public init(id: String, displayName: String, symbolName: String, capabilities: ProviderCapabilities,
                usageProvider: (any UsageProvider)? = nil, note: String? = nil, signInUnavailableText: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.symbolName = symbolName
        self.capabilities = capabilities
        self.usageProvider = usageProvider
        self.note = note
        self.signInUnavailableText = signInUnavailableText
    }

    /// Wraps a log-based provider.
    public init(_ provider: any UsageProvider, signIn: SignInKind, onlineQuota: OnlineQuotaSource,
                signInUnavailableText: String? = nil) {
        self.init(id: provider.id, displayName: provider.displayName, symbolName: provider.symbolName,
                  capabilities: ProviderCapabilities(localLogs: true, folderAccounts: true, signIn: signIn, onlineQuota: onlineQuota),
                  usageProvider: provider, signInUnavailableText: signInUnavailableText)
    }

    public var dataPathHint: String? { usageProvider?.dataPathHint }
}

/// Every provider the app shows, in display order.
///
/// `ProviderRegistry` stays the list of log parsers (scanner, coordinator, path validation); this catalog
/// wraps those entries and adds providers that have no logs, such as Muse (muse.ai).
public struct ProviderCatalog: Sendable {
    public let providers: [ProviderInfo]

    public init(providers: [ProviderInfo]) { self.providers = providers }

    public static let museAIID = "museai"

    /// Muse, Meta's personal assistant at muse.ai (not Muse Code). Weekly quota only, read with a web session.
    public static let museAI = ProviderInfo(
        id: museAIID, displayName: "Muse", symbolName: "sparkles",
        capabilities: ProviderCapabilities(localLogs: false, folderAccounts: false, signIn: .web, onlineQuota: .webSession),
        note: "Uses your muse.ai session. This is unofficial and may stop working when the site changes.")

    public static let `default`: ProviderCatalog = {
        let r = ProviderRegistry.default
        var list: [ProviderInfo] = []
        if let p = r.provider(withID: "claude") { list.append(ProviderInfo(p, signIn: .cli, onlineQuota: .cliCredentials)) }
        if let p = r.provider(withID: "codex") { list.append(ProviderInfo(p, signIn: .cli, onlineQuota: .cliCredentials)) }
        if let p = r.provider(withID: "gemini") { list.append(ProviderInfo(p, signIn: .cli, onlineQuota: .cliCredentials)) }
        list.append(museAI)
        if let p = r.provider(withID: "muse") {
            list.append(ProviderInfo(p, signIn: .none, onlineQuota: .none,
                                     signInUnavailableText: "Signing in from TokenBar is not available for Muse Code."))
        }
        // Any log provider added to the registry later still shows up.
        for p in r.providers where !list.contains(where: { $0.id == p.id }) {
            list.append(ProviderInfo(p, signIn: .none, onlineQuota: .none))
        }
        return ProviderCatalog(providers: list)
    }()

    public func info(for providerID: String) -> ProviderInfo? {
        providers.first { $0.id == providerID }
    }

    public func capabilities(of providerID: String) -> ProviderCapabilities? {
        info(for: providerID)?.capabilities
    }

    // MARK: Which accounts go where

    /// Accounts the log scanner should read (unknown providers and log-less providers are skipped).
    public func logAccounts(_ accounts: [Account]) -> [Account] {
        accounts.filter { capabilities(of: $0.providerID)?.localLogs == true }
    }

    /// Accounts `QuotaService` should handle.
    public func cliQuotaAccounts(_ accounts: [Account]) -> [Account] {
        accounts.filter { capabilities(of: $0.providerID)?.onlineQuota == .cliCredentials }
    }

    /// Enabled web-session accounts whose online switches (global and per account) are on.
    /// When this is empty the web quota service must not be called at all.
    public func webQuotaTargets(_ accounts: [Account], onlineQuotaEnabled: Bool) -> [UUID] {
        guard onlineQuotaEnabled else { return [] }
        return accounts.filter {
            $0.isEnabled && $0.onlineQuotaEnabled && capabilities(of: $0.providerID)?.onlineQuota == .webSession
        }.map(\.id)
    }

    /// Providers that can drive the menu bar number (only those with token counts).
    public var menuBarProviders: [ProviderInfo] { providers.filter(\.capabilities.localLogs) }
}
