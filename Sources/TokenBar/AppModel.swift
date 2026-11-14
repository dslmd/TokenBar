import SwiftUI
import TokenBarCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var config: AppConfig
    @Published private(set) var usage: [UUID: AccountUsage] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?

    let registry = ProviderRegistry.default
    let secrets: SecretStore = KeychainSecretStore()

    private let store = ConfigStore()
    private let coordinator = UsageCoordinator()
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
        startTimer()
    }

    // MARK: Derived state

    var accounts: [Account] { config.accounts }
    var settings: AppSettings { config.settings }

    var menuBarTitle: String {
        MenuBarSummary.title(accounts: config.accounts, usage: usage, settings: config.settings)
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
    func refresh() async {
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

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        let oldInterval = config.settings.refreshIntervalSeconds
        change(&config.settings)
        commit(refresh: false)
        if config.settings.refreshIntervalSeconds != oldInterval { startTimer() }
        objectWillChange.send()
    }
}
