import Foundation

public enum MenuBarPeriod: String, Codable, CaseIterable, Sendable {
    case today, last7Days, month
}

/// What the number next to the menu bar icon shows.
public enum MenuBarMetric: String, Codable, CaseIterable, Sendable {
    /// Tokens for `menuBarPeriod`.
    case tokens
    /// The highest current quota percentage, e.g. "93%".
    case peakQuota
}

public struct AppSettings: Codable, Equatable, Sendable {
    public static let defaultQuotaAlertThreshold = 90
    /// Thresholds offered in settings.
    public static let quotaAlertThresholdChoices = [75, 90, 95]

    public var refreshIntervalSeconds: Int
    /// nil = sum over all providers.
    public var menuBarProviderID: String?
    public var menuBarPeriod: MenuBarPeriod
    /// Whether cache read/write tokens count towards the menu bar number.
    public var menuBarIncludesCache: Bool
    /// Show the number next to the menu bar icon (false = icon only).
    public var menuBarShowsNumber: Bool
    /// Global switch for online quota (network access). Default on.
    public var onlineQuotaEnabled: Bool
    /// What the menu bar number shows. Default tokens.
    public var menuBarMetric: MenuBarMetric
    /// False until the first-launch setup window was finished or closed.
    public var hasCompletedOnboarding: Bool
    /// Notify when a quota window reaches this percentage; nil = no quota notifications.
    public var quotaAlertThreshold: Int?
    /// Notify when an account's sign-in expires or needs attention.
    public var signInAlertsEnabled: Bool

    public init(refreshIntervalSeconds: Int = 60, menuBarProviderID: String? = nil,
                menuBarPeriod: MenuBarPeriod = .today, menuBarIncludesCache: Bool = false,
                menuBarShowsNumber: Bool = true, onlineQuotaEnabled: Bool = true,
                menuBarMetric: MenuBarMetric = .tokens, hasCompletedOnboarding: Bool = false,
                quotaAlertThreshold: Int? = AppSettings.defaultQuotaAlertThreshold, signInAlertsEnabled: Bool = true) {
        self.menuBarMetric = menuBarMetric
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.quotaAlertThreshold = quotaAlertThreshold
        self.signInAlertsEnabled = signInAlertsEnabled
        self.menuBarShowsNumber = menuBarShowsNumber
        self.onlineQuotaEnabled = onlineQuotaEnabled
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.menuBarProviderID = menuBarProviderID
        self.menuBarPeriod = menuBarPeriod
        self.menuBarIncludesCache = menuBarIncludesCache
    }

    private enum CodingKeys: String, CodingKey {
        case refreshIntervalSeconds, menuBarProviderID, menuBarPeriod, menuBarIncludesCache, menuBarShowsNumber,
             onlineQuotaEnabled, menuBarMetric, hasCompletedOnboarding, quotaAlertThreshold, signInAlertsEnabled
    }

    // Tolerant decoding: unknown/missing keys fall back to defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        refreshIntervalSeconds = max(10, (try? c.decodeIfPresent(Int.self, forKey: .refreshIntervalSeconds)) ?? d.refreshIntervalSeconds)
        menuBarProviderID = (try? c.decodeIfPresent(String.self, forKey: .menuBarProviderID)) ?? nil
        menuBarPeriod = (try? c.decodeIfPresent(MenuBarPeriod.self, forKey: .menuBarPeriod)) ?? d.menuBarPeriod
        menuBarIncludesCache = (try? c.decodeIfPresent(Bool.self, forKey: .menuBarIncludesCache)) ?? d.menuBarIncludesCache
        menuBarShowsNumber = (try? c.decodeIfPresent(Bool.self, forKey: .menuBarShowsNumber)) ?? d.menuBarShowsNumber
        onlineQuotaEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .onlineQuotaEnabled)) ?? d.onlineQuotaEnabled
        menuBarMetric = (try? c.decodeIfPresent(MenuBarMetric.self, forKey: .menuBarMetric)) ?? d.menuBarMetric
        hasCompletedOnboarding = (try? c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding)) ?? d.hasCompletedOnboarding
        signInAlertsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .signInAlertsEnabled)) ?? d.signInAlertsEnabled
        // A stored 0 means "off" (nil is not written by the encoder); a missing key means the default.
        if c.contains(.quotaAlertThreshold) {
            let stored = (try? c.decodeIfPresent(Int.self, forKey: .quotaAlertThreshold)) ?? 0
            quotaAlertThreshold = (1...100).contains(stored) ? stored : nil
        } else {
            quotaAlertThreshold = d.quotaAlertThreshold
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(refreshIntervalSeconds, forKey: .refreshIntervalSeconds)
        try c.encodeIfPresent(menuBarProviderID, forKey: .menuBarProviderID)
        try c.encode(menuBarPeriod, forKey: .menuBarPeriod)
        try c.encode(menuBarIncludesCache, forKey: .menuBarIncludesCache)
        try c.encode(menuBarShowsNumber, forKey: .menuBarShowsNumber)
        try c.encode(onlineQuotaEnabled, forKey: .onlineQuotaEnabled)
        try c.encode(menuBarMetric, forKey: .menuBarMetric)
        try c.encode(hasCompletedOnboarding, forKey: .hasCompletedOnboarding)
        try c.encode(quotaAlertThreshold ?? 0, forKey: .quotaAlertThreshold)
        try c.encode(signInAlertsEnabled, forKey: .signInAlertsEnabled)
    }
}

public struct AppConfig: Codable, Equatable, Sendable {
    public var version: Int
    public var accounts: [Account]
    public var settings: AppSettings
    /// Directories the user removed (`provider|resolved path`), so automatic detection does not add them back.
    public var dismissedAccounts: [String]
    /// Notifications already shown (see `QuotaAlerts`), so they are not repeated after a relaunch.
    public var alertLedger: [String]

    public init(version: Int = 1, accounts: [Account] = [], settings: AppSettings = AppSettings(), dismissedAccounts: [String] = [],
                alertLedger: [String] = []) {
        self.version = version
        self.accounts = accounts
        self.settings = settings
        self.dismissedAccounts = dismissedAccounts
        self.alertLedger = alertLedger
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        // One malformed entry must not drop every account.
        accounts = ((try? c.decodeIfPresent([LossyAccount].self, forKey: .accounts)) ?? []).compactMap(\.account)
        settings = (try? c.decodeIfPresent(AppSettings.self, forKey: .settings)) ?? AppSettings()
        dismissedAccounts = (try? c.decodeIfPresent([String].self, forKey: .dismissedAccounts)) ?? []
        alertLedger = (try? c.decodeIfPresent([String].self, forKey: .alertLedger)) ?? []
    }
}

private struct LossyAccount: Decodable {
    var account: Account?
    init(from decoder: Decoder) throws { account = try? Account(from: decoder) }
}

/// JSON persistence of accounts and settings. API keys are never stored here.
public struct ConfigStore: Sendable {
    public let url: URL

    public init(url: URL = ConfigStore.defaultURL) { self.url = url }

    public static var defaultURL: URL {
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        #else
        let base = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config")
        #endif
        return base.appendingPathComponent("TokenBar").appendingPathComponent("config.json")
    }

    /// Returns nil when no config exists (first launch). A corrupt file is moved
    /// aside to `config.json.bak` and also reported as nil.
    public func load() -> AppConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            let backup = url.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            return nil
        }
    }

    public func save(_ config: AppConfig) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(config).write(to: url, options: .atomic)
    }
}

/// Abstraction over secret storage; the app provides a Keychain implementation.
public protocol SecretStore: Sendable {
    func secret(for accountID: UUID) -> String?
    func setSecret(_ secret: String?, for accountID: UUID) throws
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var values: [UUID: String] = [:]
    private let lock = NSLock()
    public init() {}
    public func secret(for accountID: UUID) -> String? { lock.lock(); defer { lock.unlock() }; return values[accountID] }
    public func setSecret(_ secret: String?, for accountID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        values[accountID] = secret
    }
}
