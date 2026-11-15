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
    /// Muse (muse.ai) state per account: last good usage plus the latest problem. Only accounts that are
    /// enabled and have online quota on appear here.
    @Published private(set) var webQuota: [UUID: MuseAIService.State] = [:]
    /// True while the Muse sign-in window is open.
    @Published private(set) var isSigningInToMuse = false
    /// The account the open Muse sign-in window will update ("Sign in again"); nil when adding a new one.
    @Published private(set) var museSignInAccountID: UUID?
    /// Short message after a Muse sign-in that could not be saved.
    @Published private(set) var webSignInMessage: String?

    /// Receives notifications decided by `QuotaAlerts` after each refresh (set by the app at launch).
    var deliverAlerts: (([PendingAlert]) -> Void)?

    let registry = ProviderRegistry.default
    let catalog = ProviderCatalog.default
    let secrets: SecretStore
    /// True when the model shows fixed demo data (UI snapshots): it then never reads or writes files,
    /// the Keychain or the network, and never starts timers.
    let isDemo: Bool

    private let store = ConfigStore()
    private let fileSystem = LocalFileSystem()
    private let coordinator = UsageCoordinator()
    private let quotaService: QuotaService
    private let museService: MuseAIService
    private let signIn: SignInSessions
    private var museSignIn: MuseSignInController?
    private var isRefreshingQuota = false
    private var quotaRefreshQueued = false
    private var isRefreshingWebQuota = false
    private var sweptLeftovers = false
    private var timerTask: Task<Void, Never>?
    private var refreshQueued = false
    private var lastScan: Date?
    private static let rescanInterval: TimeInterval = 300

    /// `~/Library/Application Support/TokenBar/accounts`: homes created by "Sign in to another account".
    static var managedRoot: URL {
        ConfigStore.defaultURL.deletingLastPathComponent().appendingPathComponent("accounts")
    }

    /// The managed root spelled the way `CLILoginDriver` spells it, so detection rebuilds the exact
    /// path strings the driver handed out (Claude's Keychain item name depends on them).
    static var managedRootPath: String {
        var root = managedRoot.standardizedFileURL.path
        while root.count > 1 && root.hasSuffix("/") { root.removeLast() }
        return root
    }

    /// The live model (demo or real), for the app delegate's launch and termination hooks.
    private(set) static weak var current: AppModel?

    init() {
        isDemo = false
        secrets = KeychainSecretStore()
        quotaService = QuotaService.standard(keychain: { service in KeychainBlobStore(service: service) })
        config = store.load() ?? AppConfig()
        // Stateless Keychain access: a second instance reads the same items as `secrets`.
        museService = MuseAIService(secrets: KeychainSecretStore())
        let driver = CLILoginDriver(managedRoot: Self.managedRoot)
        // Lets a Claude sign-in finish as soon as its Keychain item exists; attributes only, so it never prompts.
        driver.setClaudeKeychainProbe { service in KeychainItemProbe.exists(service: service) }
        signIn = SignInSessions(driver: driver)
        signIn.onChange = { [weak self] in
            guard let self else { return }
            self.signInPhases = self.signIn.phases
        }
        signIn.onSuccess = { [weak self] providerID, homePath in
            self?.registerSignedInAccount(providerID: providerID, homePath: homePath)
        }
        syncLaunchAtLogin()
        Self.current = self
        startTimer()
    }

    /// A model that shows `demo` as it is and stays that way: nothing is loaded, scanned, fetched or saved.
    /// Used by snapshot mode (`TokenBar --snapshot <dir>`).
    init(demo: DemoState) {
        isDemo = true
        secrets = InMemorySecretStore()
        quotaService = QuotaService.standard(keychain: nil)
        config = demo.config
        museService = MuseAIService(secrets: InMemorySecretStore())
        signIn = SignInSessions(driver: DemoLoginDriver(managedRootPath: Self.managedRootPath))
        usage = demo.usage
        quota = demo.quota
        identities = demo.identities
        webQuota = demo.webQuota
        signInPhases = demo.signInPhases
        hasScanned = demo.hasScanned
        isScanning = demo.isScanning
        lastRefresh = demo.lastRefresh
        Self.current = self
    }

    /// The model for a normal launch, or a demo model for `TokenBar --demo [scenario]` (default `rich`;
    /// see `DemoScenario` for the names). Demo mode runs the real menu bar app without touching the
    /// user's accounts, the Keychain or the network.
    static func forLaunch(arguments: [String] = CommandLine.arguments) -> AppModel {
        guard let flag = arguments.firstIndex(of: "--demo") else { return AppModel() }
        let name = flag + 1 < arguments.count ? arguments[flag + 1] : ""
        let scenario = DemoScenario(rawValue: name) ?? .rich
        return AppModel(demo: scenario.state(home: NSHomeDirectory()))
    }

    /// Called when the app quits: stops sign-ins still in progress (CLI child processes are not killed
    /// automatically) and closes an open Muse sign-in window.
    func prepareForTermination() {
        signIn.cancelAll()
        museSignIn?.cancel()
    }

    // MARK: Derived state

    var accounts: [Account] { config.accounts }
    var enabledAccounts: [Account] { config.accounts.filter(\.isEnabled) }
    var settings: AppSettings { config.settings }

    var menuBarTitle: String {
        MenuBarSummary.title(accounts: enabledAccounts, usage: usage, settings: config.settings,
                             peakQuotaPercent: peakQuotaPercent)
    }

    /// Today's tokens over all enabled accounts (cache counted as the menu bar setting says).
    var todayTotal: Int {
        enabledAccounts.compactMap { usage[$0.id] }.reduce(0) { $0 + displayTotal($1.today) }
    }

    /// Current quota windows of an account: online data when present, otherwise from local logs; for
    /// Muse, the weekly window read from muse.ai.
    func quotaWindows(for account: Account) -> (windows: [QuotaWindow], observedAt: Date?, isOnline: Bool) {
        if catalog.capabilities(of: account.providerID)?.onlineQuota == .webSession {
            guard let usage = webQuota[account.id]?.usage else { return ([], nil, true) }
            return (usage.windows, usage.observedAt, true)
        }
        guard let effective = QuotaMerge.effective(local: usage[account.id]?.quota, online: quota[account.id]?.observation) else {
            return ([], nil, false)
        }
        return (effective.observation.windows, effective.observation.observedAt, effective.isOnline)
    }

    /// The window closest to running out, for one-line summaries.
    func peakWindow(for account: Account, now: Date = Date()) -> QuotaWindow? {
        QuotaMerge.peakWindow(quotaWindows(for: account).windows, now: now)
    }

    /// A problem the user has to act on (expired sign-in, missing folder), as a sentence; nil when none.
    func attentionMessage(for account: Account) -> String? {
        let (health, text) = health(of: account)
        switch health {
        case .warning, .error: return text
        default: return nil
        }
    }

    /// Whether the first-launch setup window should open.
    var needsOnboarding: Bool { !isDemo && !config.settings.hasCompletedOnboarding }

    func completeOnboarding() {
        guard !config.settings.hasCompletedOnboarding else { return }
        updateSettings { $0.hasCompletedOnboarding = true }
    }

    /// Warning state for the menu bar icon: any current quota window above 90 %.
    /// Muse accounts count here (their weekly quota) but never towards the token number.
    var peakQuotaPercent: Double? {
        let online = quota.merging(MuseAIAccounts.quotaResults(webQuota)) { cli, _ in cli }
        return QuotaMerge.peakPercent(accounts: enabledAccounts, usage: usage, quota: online,
                                      providerID: config.settings.menuBarProviderID, now: Date())
    }

    var menuBarWarning: Bool { (peakQuotaPercent ?? 0) >= 90 }
    var menuBarSymbol: String { menuBarWarning ? "exclamationmark.triangle.fill" : "chart.bar.fill" }

    /// Number shown in cards, following the "include cache" preference of the menu bar.
    func displayTotal(_ b: TokenBreakdown) -> Int {
        config.settings.menuBarIncludesCache ? b.total : b.totalExcludingCache
    }

    func capabilities(of providerID: String) -> ProviderCapabilities? {
        catalog.capabilities(of: providerID)
    }

    /// Whether TokenBar can read online quota for this provider (Muse Code: no).
    func supportsOnlineQuota(_ providerID: String) -> Bool {
        catalog.capabilities(of: providerID)?.hasOnlineQuota == true
    }

    func accounts(for providerID: String) -> [Account] {
        config.accounts.filter { $0.providerID == providerID }
    }

    func enabledAccounts(for providerID: String) -> [Account] {
        accounts(for: providerID).filter(\.isEnabled)
    }

    func health(of account: Account) -> (AccountHealth, String) {
        switch catalog.capabilities(of: account.providerID)?.onlineQuota {
        case .webSession?:
            return MuseAIAccounts.health(account: account, state: webQuota[account.id], onlineQuotaEnabled: config.settings.onlineQuotaEnabled)
        default:
            return AccountHealth.evaluate(account: account, usage: usage[account.id], quota: quota[account.id])
        }
    }

    /// Whether online quota is on for this account (global and per-account switch).
    func onlineQuotaIsOn(for account: Account) -> Bool {
        config.settings.onlineQuotaEnabled && account.onlineQuotaEnabled
    }

    // MARK: Refresh

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.lastScan.map({ Date().timeIntervalSince($0) >= Self.rescanInterval }) ?? true {
                    await self.rescan()
                    self.sweepLeftoverSignInsOnce()
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
        guard !isDemo else { return }
        guard !isRefreshing else { refreshQueued = true; return }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshQueued = false
            let logAccounts = catalog.logAccounts(enabledAccounts)
            let result = await coordinator.refresh(accounts: logAccounts)
            let live = Set(logAccounts.map(\.id))
            usage = result.filter { live.contains($0.key) }
            lastRefresh = Date()
        } while refreshQueued
        // Network work never delays the local numbers: it runs on its own and is throttled by the services.
        Task { await self.refreshQuota(force: force) }
        Task { await self.refreshWebQuota(force: force) }
    }

    func refreshQuota(force: Bool = false) async {
        // A forced request that arrives mid-cycle (a switch was flipped, or a manual refresh)
        // runs right after instead of being dropped.
        guard !isDemo else { return }
        guard !isRefreshingQuota else { if force { quotaRefreshQueued = true }; return }
        isRefreshingQuota = true
        defer { isRefreshingQuota = false }
        var forceNext = force
        repeat {
            quotaRefreshQueued = false
            let accounts = catalog.cliQuotaAccounts(enabledAccounts)
            let result = await quotaService.refresh(accounts: accounts,
                                                    enabled: config.settings.onlineQuotaEnabled, force: forceNext)
            let live = Set(catalog.cliQuotaAccounts(enabledAccounts).map(\.id))
            quota = result.filter { live.contains($0.key) }
            forceNext = true
        } while quotaRefreshQueued
        evaluateAlerts()
    }

    /// Muse accounts. The service throttles itself; with online quota off (globally or for the account)
    /// it is not called at all.
    func refreshWebQuota(force: Bool = false) async {
        guard !isDemo else { return }
        guard !isRefreshingWebQuota else { return }
        isRefreshingWebQuota = true
        defer { isRefreshingWebQuota = false }
        let targets = catalog.webQuotaTargets(config.accounts, onlineQuotaEnabled: config.settings.onlineQuotaEnabled)
        var states: [UUID: MuseAIService.State] = [:]
        if !targets.isEmpty {
            _ = await museService.refresh(accountIDs: targets, force: force)
            // Read back the latest state: a re-sign-in may have finished while the batch ran.
            for id in targets { states[id] = await museService.state(for: id) }
        }
        let live = Set(catalog.webQuotaTargets(config.accounts, onlineQuotaEnabled: config.settings.onlineQuotaEnabled))
        webQuota = states.filter { live.contains($0.key) }
        evaluateAlerts()
    }

    private func refreshWebQuota(accountID id: UUID) async {
        guard !isDemo else { return }
        guard catalog.webQuotaTargets(config.accounts, onlineQuotaEnabled: config.settings.onlineQuotaEnabled).contains(id) else { return }
        let state = await museService.refresh(accountID: id, force: true)
        if catalog.webQuotaTargets(config.accounts, onlineQuotaEnabled: config.settings.onlineQuotaEnabled).contains(id) {
            webQuota[id] = state
        }
    }

    // MARK: Notifications

    /// Builds what `QuotaAlerts` needs from the current state.
    func alertInputs() -> [QuotaAlerts.Input] {
        enabledAccounts.map { account in
            let name = catalog.info(for: account.providerID)?.displayName ?? account.providerID
            let windows = quotaWindows(for: account).windows
            if catalog.capabilities(of: account.providerID)?.onlineQuota == .webSession {
                let state = webQuota[account.id]
                let problem = state?.failure.flatMap { $0.needsSignIn ? $0.message : nil }
                return QuotaAlerts.Input(account: account, providerName: name, windows: windows,
                                         signInProblem: problem, isKnown: state != nil)
            }
            let result = quota[account.id]
            return QuotaAlerts.Input(account: account, providerName: name, windows: windows,
                                     signInProblem: QuotaAlerts.signInProblem(for: result?.issue), isKnown: result != nil)
        }
    }

    /// Shows notifications that became due and remembers them (in the config) so they are not repeated.
    private func evaluateAlerts() {
        guard !isDemo else { return }
        let plan = QuotaAlerts.plan(inputs: alertInputs(), settings: config.settings, ledger: config.alertLedger,
                                    existingAccountIDs: Set(config.accounts.map(\.id)), now: Date())
        if plan.ledger != config.alertLedger {
            config.alertLedger = plan.ledger
            commit(refresh: false)
        }
        deliverAlerts?(plan.alerts)
    }

    /// Example notifications built from the current (demo) data with an empty memory, for checking how
    /// they look (`--sample-notifications`).
    func sampleAlerts() -> [PendingAlert] {
        var settings = config.settings
        settings.quotaAlertThreshold = settings.quotaAlertThreshold ?? AppSettings.defaultQuotaAlertThreshold
        settings.signInAlertsEnabled = true
        return QuotaAlerts.plan(inputs: alertInputs(), settings: settings, ledger: [],
                                existingAccountIDs: Set(config.accounts.map(\.id)), now: Date()).alerts
    }

    func refreshIfStale(olderThan seconds: TimeInterval = 15) {
        if let last = lastRefresh, Date().timeIntervalSince(last) < seconds { return }
        Task { await refresh() }
    }

    // MARK: Automatic detection

    /// Looks for accounts on this Mac (default homes, profile folders, shell start-up files, TokenBar sign-ins),
    /// adds new ones, keeps removed ones removed, and refreshes the signed-in identities. Disk work runs off the main thread.
    func rescan() async {
        guard !isDemo, !isScanning else { return }
        isScanning = true
        defer { isScanning = false; hasScanned = true; lastScan = Date() }
        let fs = fileSystem
        let discovery = AccountDiscovery(fileSystem: fs, managedRoot: Self.managedRootPath,
                                         isManagedHome: { [driver = signIn.driver] in driver.isManagedHome($0) })
        let found = await Task.detached(priority: .utility) { discovery.discover() }.value
        var updated = config
        if AccountReconciler.merge(found, into: &updated, fileSystem: fs) {
            config = updated
            commit(refresh: true)
        }
        await reloadIdentities()
    }

    /// Once per launch, after the first scan: deletes managed homes that no account uses and that are older
    /// than an hour (sign-ins interrupted by a crash). Deletion goes through the driver, which only touches
    /// directories inside the managed root.
    private func sweepLeftoverSignInsOnce() {
        guard !sweptLeftovers else { return }
        sweptLeftovers = true
        let fs = fileSystem
        let accounts = config.accounts
        let driver = signIn.driver
        let root = Self.managedRootPath
        Task.detached(priority: .utility) {
            let leftovers = SignInSessions.orphanedManagedHomes(
                root: root, accounts: accounts, fileSystem: fs,
                modificationDate: { path in
                    (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
                },
                now: Date())
            for home in leftovers { driver.removeManagedHome(at: home) }
        }
    }

    private func reloadIdentities() async {
        guard !isDemo else { return }
        let fs = fileSystem
        let targets = catalog.logAccounts(config.accounts).map { ($0.id, $0.providerID, normalizedPath($0.dataPath, home: fs.homeDirectory)) }
        identities = await Task.detached(priority: .utility) { () -> [UUID: AccountIdentity] in
            var out: [UUID: AccountIdentity] = [:]
            for (id, provider, path) in targets {
                out[id] = AccountIdentityReader.read(providerID: provider, dataPath: path, fileSystem: fs)
            }
            return out
        }.value
    }

    // MARK: Sign in to another account

    /// Nil when the provider offers sign-in from TokenBar; otherwise the reason to show instead of a button.
    func signInUnavailableReason(_ providerID: String) -> String? {
        guard let info = catalog.info(for: providerID) else { return "Sign-in is not supported for this provider." }
        switch info.capabilities.signIn {
        case .web: return nil
        case .cli: return signIn.unavailableReason(providerID: providerID)
        case .none: return info.signInUnavailableText ?? "Signing in from TokenBar is not available for \(info.displayName)."
        }
    }

    func startSignIn(_ providerID: String) {
        guard !isDemo else { return }
        if catalog.capabilities(of: providerID)?.signIn == .web {
            signInToMuse()
        } else {
            signIn.start(providerID)
        }
    }
    func cancelSignIn(_ providerID: String) { signIn.cancel(providerID) }
    func dismissSignIn(_ providerID: String) { signIn.dismiss(providerID) }

    /// Registers the managed home exactly as the driver reported it (see `AccountReconciler.add`).
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
        guard catalog.capabilities(of: account.providerID)?.folderAccounts == true,
              let path = SignInSessions.managedAccountPath(for: account, driver: signIn.driver) else { return nil }
        return signIn.driver.shellAlias(providerID: account.providerID, homePath: path)
    }

    // MARK: Muse (muse.ai) sign-in

    /// Opens the Muse sign-in window. With `accountID`, the new session replaces that account's stored
    /// session ("Sign in again"); otherwise a new account is added. Only one window at a time.
    func signInToMuse(replacing accountID: UUID? = nil) {
        guard !isDemo else { return }
        if let open = museSignIn {
            open.bringToFront()
            return
        }
        webSignInMessage = nil
        let controller = MuseSignInController()
        museSignIn = controller
        isSigningInToMuse = true
        museSignInAccountID = accountID
        controller.begin { [weak self] result in
            guard let self else { return }
            self.museSignIn = nil
            self.isSigningInToMuse = false
            self.museSignInAccountID = nil
            if case .signedIn(let credentials) = result {
                Task { await self.finishMuseSignIn(credentials, replacing: accountID) }
            }
        }
    }

    func cancelMuseSignIn() {
        museSignIn?.cancel()
    }

    func dismissWebSignInMessage() { webSignInMessage = nil }

    private func finishMuseSignIn(_ credentials: MuseSignInCredentials, replacing accountID: UUID?) async {
        if let id = accountID {
            // The account was removed while the window was open: do not bring it back.
            guard config.accounts.contains(where: { $0.id == id }) else { return }
            do { try secrets.setSecret(credentials.cookieSecret, for: id) } catch {
                webSignInMessage = "Could not save the Muse session in the Keychain. Try again."
                return
            }
            await refreshWebQuota(accountID: id)
            return
        }
        let names = accounts(for: ProviderCatalog.museAIID).map(\.name)
        let name = MuseAIAccounts.defaultName(accountLabel: credentials.accountLabel, planName: credentials.planName, existingNames: names)
        var updated = config
        let account = AccountReconciler.addWebAccount(providerID: ProviderCatalog.museAIID, name: name, to: &updated)
        // The session goes to the Keychain only, never into config.json; no account without a stored session.
        do { try secrets.setSecret(credentials.cookieSecret, for: account.id) } catch {
            webSignInMessage = "Could not save the Muse session in the Keychain. Try again."
            return
        }
        config = updated
        commit(refresh: false)
        await refreshWebQuota(accountID: account.id)
    }

    // MARK: Mutations (each persists immediately)

    private func commit(refresh: Bool = true) {
        guard !isDemo else { return }
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
        webQuota.removeValue(forKey: id)
        identities.removeValue(forKey: id)
        try? secrets.setSecret(nil, for: id)
        commit(refresh: false)
        if catalog.capabilities(of: account.providerID)?.onlineQuota == .webSession {
            Task { await self.museService.forget(accountID: id) }
        }
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
            webQuota.removeValue(forKey: id)
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
        if !enabled { webQuota.removeValue(forKey: id) }
        commit(refresh: false)
        if catalog.capabilities(of: config.accounts[i].providerID)?.onlineQuota == .webSession {
            Task { await refreshWebQuota(force: true) }
        } else {
            Task { await refreshQuota(force: true) }
        }
    }

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        let old = config.settings
        change(&config.settings)
        commit(refresh: false)
        if config.settings.refreshIntervalSeconds != old.refreshIntervalSeconds { startTimer() }
        if config.settings.onlineQuotaEnabled != old.onlineQuotaEnabled {
            Task { await refreshQuota(force: true) }
            Task { await refreshWebQuota(force: true) }
        }
    }

    // MARK: Launch at login (macOS 13+)

    func setLaunchAtLogin(_ enabled: Bool) {
        guard !isDemo else { return }
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
