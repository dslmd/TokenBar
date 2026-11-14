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
    /// Signed-in identity per account, read from the CLI's local files.
    @Published private(set) var identities: [UUID: AccountIdentity] = [:]
    @Published private(set) var isScanning = false
    /// False until the first automatic scan has finished, so the UI can say "Looking for accounts".
    @Published private(set) var hasScanned = false
    @Published private(set) var signInPhases: [String: LoginPhase] = [:]
    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginNeedsApproval = false

    let registry = ProviderRegistry.default
    let secrets: SecretStore = KeychainSecretStore()

    private let store = ConfigStore()
    private let fileSystem = LocalFileSystem()
    private let coordinator = UsageCoordinator()
    private let quotaService = QuotaService.standard(keychain: { service in KeychainBlobStore(service: service) })
    private let signIn: SignInSessions
    private var isRefreshingQuota = false
    private var timerTask: Task<Void, Never>?
    private var refreshQueued = false
    private var lastScan: Date?
    private static let rescanInterval: TimeInterval = 300

    /// `~/Library/Application Support/TokenBar/accounts`: homes created by "Sign in to another account".
    static var managedRoot: URL {
        ConfigStore.defaultURL.deletingLastPathComponent().appendingPathComponent("accounts")
    }

    init() {
        config = store.load() ?? AppConfig()
        signIn = SignInSessions(driver: CLILoginDriver(managedRoot: Self.managedRoot))
        signIn.onChange = { [weak self] in
            guard let self else { return }
            self.signInPhases = self.signIn.phases
        }
        signIn.onSuccess = { [weak self] providerID, homePath in
            self?.registerSignedInAccount(providerID: providerID, homePath: homePath)
        }
        syncLaunchAtLogin()
        startTimer()
    }

    // MARK: Derived state

    var accounts: [Account] { config.accounts }
    var enabledAccounts: [Account] { config.accounts.filter(\.isEnabled) }
    var settings: AppSettings { config.settings }

    var menuBarTitle: String {
        MenuBarSummary.title(accounts: enabledAccounts, usage: usage, settings: config.settings)
    }

    /// Warning state for the menu bar icon: any current quota window above 90 %.
    var peakQuotaPercent: Double? {
        QuotaMerge.peakPercent(accounts: enabledAccounts, usage: usage, quota: quota, providerID: config.settings.menuBarProviderID, now: Date())
    }

    var menuBarWarning: Bool { (peakQuotaPercent ?? 0) >= 90 }
    var menuBarSymbol: String { menuBarWarning ? "exclamationmark.triangle.fill" : "chart.bar.fill" }

    /// Number shown in cards, following the "include cache" preference of the menu bar.
    func displayTotal(_ b: TokenBreakdown) -> Int {
        config.settings.menuBarIncludesCache ? b.total : b.totalExcludingCache
    }

    /// Whether TokenBar knows an online quota endpoint for this provider (Muse Code: no).
    func backendSupportsOnlineQuota(_ providerID: String) -> Bool {
        QuotaService.supportedProviderIDs.contains(providerID)
    }

    func accounts(for providerID: String) -> [Account] {
        config.accounts.filter { $0.providerID == providerID }
    }

    func enabledAccounts(for providerID: String) -> [Account] {
        accounts(for: providerID).filter(\.isEnabled)
    }

    func health(of account: Account) -> (AccountHealth, String) {
        AccountHealth.evaluate(account: account, usage: usage[account.id], quota: quota[account.id])
    }

    // MARK: Refresh

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.lastScan.map({ Date().timeIntervalSince($0) >= Self.rescanInterval }) ?? true {
                    await self.rescan()
                }
                await self.refresh()
                let seconds = self.config.settings.refreshIntervalSeconds
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
            let result = await coordinator.refresh(accounts: enabledAccounts)
            let live = Set(enabledAccounts.map(\.id))
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
        let result = await quotaService.refresh(accounts: enabledAccounts,
                                                enabled: config.settings.onlineQuotaEnabled, force: force)
        let live = Set(enabledAccounts.map(\.id))
        quota = result.filter { live.contains($0.key) }
    }

    func refreshIfStale(olderThan seconds: TimeInterval = 15) {
        if let last = lastRefresh, Date().timeIntervalSince(last) < seconds { return }
        Task { await refresh() }
    }

    // MARK: Automatic detection

    /// Looks for accounts on this Mac (default homes, profile folders, shell start-up files, TokenBar sign-ins),
    /// adds new ones, keeps removed ones removed, and refreshes the signed-in identities. Disk work runs off the main thread.
    func rescan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false; hasScanned = true; lastScan = Date() }
        let fs = fileSystem
        let discovery = AccountDiscovery(fileSystem: fs, managedRoot: Self.managedRoot.path,
                                         isManagedHome: { [driver = signIn.driver] in driver.isManagedHome($0) })
        let found = await Task.detached(priority: .utility) { discovery.discover() }.value
        var updated = config
        if AccountReconciler.merge(found, into: &updated, fileSystem: fs) {
            config = updated
            commit(refresh: true)
        }
        await reloadIdentities()
    }

    private func reloadIdentities() async {
        let fs = fileSystem
        let targets = config.accounts.map { ($0.id, $0.providerID, normalizedPath($0.dataPath, home: fs.homeDirectory)) }
        identities = await Task.detached(priority: .utility) { () -> [UUID: AccountIdentity] in
            var out: [UUID: AccountIdentity] = [:]
            for (id, provider, path) in targets {
                out[id] = AccountIdentityReader.read(providerID: provider, dataPath: path, fileSystem: fs)
            }
            return out
        }.value
    }

    // MARK: Sign in to another account

    func signInUnavailableReason(_ providerID: String) -> String? {
        signIn.unavailableReason(providerID: providerID)
    }

    func startSignIn(_ providerID: String) { signIn.start(providerID) }
    func cancelSignIn(_ providerID: String) { signIn.cancel(providerID) }
    func dismissSignIn(_ providerID: String) { signIn.dismiss(providerID) }

    private func registerSignedInAccount(providerID: String, homePath: String) {
        let path = AccountReconciler.dataPath(forManagedHome: homePath, providerID: providerID, fileSystem: fileSystem)
        AccountReconciler.add(providerID: providerID, dataPath: path, origin: .signedIn, name: nil, to: &config, fileSystem: fileSystem)
        commit(refresh: false)
        Task {
            await self.rescan()          // picks up the email for the name
            await self.refresh(force: true)
        }
    }

    /// A shell alias that runs the CLI with a TokenBar-managed profile, for accounts signed in here.
    func shellAlias(for account: Account) -> String? {
        guard let home = SignInSessions.managedHomeToRemove(for: account, driver: signIn.driver, home: fileSystem.homeDirectory) else { return nil }
        return signIn.driver.shellAlias(providerID: account.providerID, homePath: home)
    }

    // MARK: Mutations (each persists immediately)

    private func commit(refresh: Bool = true) {
        try? store.save(config)
        if refresh { Task { await self.refresh() } }
    }

    /// Adds a folder chosen by hand (the Advanced path). Returns the validation result.
    @discardableResult
    func addManualAccount(providerID: String, path: String) -> PathValidation {
        guard let provider = registry.provider(withID: providerID) else { return .missing }
        let validation = provider.validate(dataPath: path)
        guard validation.isValid else { return validation }
        AccountReconciler.add(providerID: providerID, dataPath: path, origin: .manual, name: nil, to: &config, fileSystem: fileSystem)
        commit()
        Task { await self.reloadIdentities() }
        return validation
    }

    /// Removes an account. Detected accounts are remembered as dismissed so detection does not add them back;
    /// for an account signed in here, TokenBar's own managed home (and the sign-in in it) is deleted.
    func removeAccount(_ id: UUID) {
        guard let account = config.accounts.first(where: { $0.id == id }) else { return }
        let managedHome = SignInSessions.managedHomeToRemove(for: account, driver: signIn.driver, home: fileSystem.homeDirectory)
        AccountReconciler.remove(id, from: &config, fileSystem: fileSystem)
        usage.removeValue(forKey: id)
        quota.removeValue(forKey: id)
        identities.removeValue(forKey: id)
        try? secrets.setSecret(nil, for: id)
        commit(refresh: false)
        if let managedHome {
            let driver = signIn.driver
            Task.detached(priority: .utility) { driver.removeManagedHome(at: managedHome) }
        }
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = config.accounts.firstIndex(where: { $0.id == id }), config.accounts[i].name != name else { return }
        config.accounts[i].name = name
        config.accounts[i].autoNamed = false
        commit(refresh: false)
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let i = config.accounts.firstIndex(where: { $0.id == id }), config.accounts[i].isEnabled != enabled else { return }
        config.accounts[i].isEnabled = enabled
        if !enabled {
            usage.removeValue(forKey: id)
            quota.removeValue(forKey: id)
        }
        commit()
    }

    func setDataPath(_ id: UUID, to path: String) {
        guard let i = config.accounts.firstIndex(where: { $0.id == id }), config.accounts[i].dataPath != path else { return }
        config.accounts[i].dataPath = path
        config.accounts[i].origin = .manual
        commit()
        Task { await self.reloadIdentities() }
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
