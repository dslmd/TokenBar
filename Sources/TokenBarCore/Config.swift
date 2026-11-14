import Foundation

public enum MenuBarPeriod: String, Codable, CaseIterable, Sendable {
    case today, last7Days, month
}

public struct AppSettings: Codable, Equatable, Sendable {
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

    public init(refreshIntervalSeconds: Int = 60, menuBarProviderID: String? = nil,
                menuBarPeriod: MenuBarPeriod = .today, menuBarIncludesCache: Bool = false,
                menuBarShowsNumber: Bool = true, onlineQuotaEnabled: Bool = true) {
        self.menuBarShowsNumber = menuBarShowsNumber
        self.onlineQuotaEnabled = onlineQuotaEnabled
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.menuBarProviderID = menuBarProviderID
        self.menuBarPeriod = menuBarPeriod
        self.menuBarIncludesCache = menuBarIncludesCache
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
    }
}

public struct AppConfig: Codable, Equatable, Sendable {
    public var version: Int
    public var accounts: [Account]
    public var settings: AppSettings

    public init(version: Int = 1, accounts: [Account] = [], settings: AppSettings = AppSettings()) {
        self.version = version
        self.accounts = accounts
        self.settings = settings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        accounts = (try? c.decodeIfPresent([Account].self, forKey: .accounts)) ?? []
        settings = (try? c.decodeIfPresent(AppSettings.self, forKey: .settings)) ?? AppSettings()
    }
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

/// First-launch detection of default accounts.
public enum AccountDetector {
    public static func detectDefaultAccounts(
        registry: ProviderRegistry = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        fileManager: FileManager = .default
    ) -> [Account] {
        var accounts: [Account] = []
        for provider in registry.providers {
            var seen = Set<String>()
            var found: [String] = []
            for candidate in provider.defaultDataPaths(environment: environment, home: home) {
                let path = expandPath(candidate)
                let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                guard !seen.contains(resolved) else { continue }
                let hasRoot = provider.scanRoots(forDataPath: path).contains { root in
                    var isDir: ObjCBool = false
                    return fileManager.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue
                }
                if hasRoot { seen.insert(resolved); found.append(path) }
            }
            for (i, path) in found.enumerated() {
                let name = i == 0 ? "默认" : URL(fileURLWithPath: path).lastPathComponent
                accounts.append(Account(providerID: provider.id, name: name, dataPath: path))
            }
        }
        return accounts
    }
}
