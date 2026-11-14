import SwiftUI
import ServiceManagement
import TokenBarCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var config: AppConfig
    @Published private(set) var usage: [UUID: AccountUsage] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    /// Online quota per account (separate from local token numbers so a network problem never hides them).
    @Published private(set) var quota: [UUID: QuotaResult] = [:]
    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginNeedsApproval = false

    let registry = ProviderRegistry.default
    let secrets: SecretStore = KeychainSecretStore()

    private let store = ConfigStore()
    private let coordinator = UsageCoordinator()
    private let quotaService = QuotaService.standard(keychain: { service in KeychainBlobStore(service: service) })
    private var isRefreshingQuota = false
    private var timerTask: Task<Void, Never>?
    private var refreshQueued = false

    init() {
        if let saved = store.load() {
            config = saved
        } else {
            // First launch: pick up default accounts for every CLI that is installed.
            config = AppConfig(accounts: AccountDetector.detectDefaultAccounts())
            try? store.save(config)
        }
        syncLaunchAtLogin()
        startTimer()
    }

    // MARK: Derived state

    var accounts: [Account] { config.accounts }
    var settings: AppSettings { config.settings }

    var menuBarTitle: String {
        MenuBarSummary.title(accounts: config.accounts, usage: usage, settings: config.settings)
    }

    /// Warning state for the menu bar icon: any current quota window above 90 %.
    var peakQuotaPercent: Double? {
        QuotaMerge.peakPercent(accounts: config.accounts, usage: usage, quota: quota, providerID: config.settings.menuBarProviderID, now: Date())
    }

    var menuBarWarning: Bool { (peakQuotaPercent ?? 0) >= 90 }
    var menuBarSymbol: String { menuBarWarning ? "exclamationmark.triangle.fill" : "chart.bar.fill" }

    /// Number shown in cards, following the "include cache" preference of the menu bar.
    func displayTotal(_ b: TokenBreakdown) -> Int {
        config.settings.menuBarIncludesCache ? b.total : b.totalExcludingCache
    }

    /// Whether TokenBar knows an online quota endpoint for this provider (Muse: no).
    func backendSupportsOnlineQuota(_ providerID: String) -> Bool {
        QuotaService.supportedProviderIDs.contains(providerID)
    }

    func accounts(for providerID: String) -> [Account] {
        config.accounts.filter { $0.providerID == providerID }
    }

    // MARK: Refresh

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let seconds = self?.config.settings.refreshIntervalSeconds ?? 60
                try? await Task.sleep(nanoseconds: UInt64(max(10, seconds)) * 1_000_000_000)
            }
        }
    }

    /// Parsing happens inside `UsageCoordinator` (an actor), i.e. off the main thread.
    func refresh(force: Bool = false) async {
        // A request that arrives mid-refresh (e.g. an account was just added) is
        // remembered and run right after, instead of being dropped.
        guard !isRefreshing else { refreshQueued = true; return }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshQueued = false
            let accounts = config.accounts
            let result = await coordinator.refresh(accounts: accounts)
            let live = Set(config.accounts.map(\.id))
            usage = result.filter { live.contains($0.key) }
            lastRefresh = Date()
        } while refreshQueued
        // Network work never delays the local numbers: it runs on its own and is throttled by QuotaService.
        Task { await self.refreshQuota(force: force) }
    }

    func refreshQuota(force: Bool = false) async {
        guard !isRefreshingQuota else { return }
        isRefreshingQuota = true
        defer { isRefreshingQuota = false }
        let result = await quotaService.refresh(accounts: config.accounts,
                                                enabled: config.settings.onlineQuotaEnabled, force: force)
        let live = Set(config.accounts.map(\.id))
        quota = result.filter { live.contains($0.key) }
    }

    func refreshIfStale(olderThan seconds: TimeInterval = 15) {
        if let last = lastRefresh, Date().timeIntervalSince(last) < seconds { return }
        Task { await refresh() }
    }

    // MARK: Mutations (each persists immediately)

    private func commit(refresh: Bool = true) {
        try? store.save(config)
        if refresh { Task { await self.refresh() } }
    }

    @discardableResult
    func addAccount(providerID: String) -> Account? {
        guard let provider = registry.provider(withID: providerID) else { return nil }
        let n = accounts(for: providerID).count + 1
        let path = provider.defaultDataPaths(environment: [:], home: URL(fileURLWithPath: NSHomeDirectory())).last ?? ""
        let account = Account(providerID: providerID, name: "账户 \(n)", dataPath: path)
        config.accounts.append(account)
        commit()
        return account
    }

    func removeAccount(_ id: UUID) {
        config.accounts.removeAll { $0.id == id }
        usage.removeValue(forKey: id)
        quota.removeValue(forKey: id)
        try? secrets.setSecret(nil, for: id)
        commit(refresh: false)
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = config.accounts.firstIndex(where: { $0.id == id }), config.accounts[i].name != name else { return }
        config.accounts[i].name = name
        commit(refresh: false)
    }

    func setDataPath(_ id: UUID, to path: String) {
        guard let i = config.accounts.firstIndex(where: { $0.id == id }), config.accounts[i].dataPath != path else { return }
        config.accounts[i].dataPath = path
        commit()
    }

    /// Adds detected default accounts whose data path is not configured yet.
    func redetectDefaults() {
        let known = Set(config.accounts.map { "\($0.providerID)|\(expandPath($0.dataPath))" })
        let fresh = AccountDetector.detectDefaultAccounts().filter {
            !known.contains("\($0.providerID)|\(expandPath($0.dataPath))")
        }
        guard !fresh.isEmpty else { return }
        config.accounts.append(contentsOf: fresh)
        commit()
    }

    func setOnlineQuota(_ id: UUID, enabled: Bool) {
        guard let i = config.accounts.firstIndex(where: { $0.id == id }), config.accounts[i].onlineQuotaEnabled != enabled else { return }
        config.accounts[i].onlineQuotaEnabled = enabled
        commit(refresh: false)
        Task { await refreshQuota(force: true) }
    }

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        let old = config.settings
        change(&config.settings)
        commit(refresh: false)
        if config.settings.refreshIntervalSeconds != old.refreshIntervalSeconds { startTimer() }
        if config.settings.onlineQuotaEnabled != old.onlineQuotaEnabled { Task { await refreshQuota(force: true) } }
    }

    // MARK: Launch at login (macOS 13+)

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            // Fall through: the re-read below shows the real state (e.g. unsigned dev builds).
        }
        syncLaunchAtLogin()
    }

    private func syncLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        launchAtLogin = (status == .enabled)
        launchAtLoginNeedsApproval = (status == .requiresApproval)
    }
}
