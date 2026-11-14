import Foundation

/// Owns the incremental scanners and runs all parsing off the main thread
/// (an actor that is not `@MainActor` executes on the cooperative pool).
public actor UsageCoordinator {
    private let registry: ProviderRegistry
    private var scanners: [UUID: AccountScanner] = [:]

    public init(registry: ProviderRegistry = .default) {
        self.registry = registry
    }

    /// Refreshes every account and returns usage keyed by account id.
    public func refresh(accounts: [Account], now: Date = Date(),
                        calendar: Calendar = .current) -> [UUID: AccountUsage] {
        var result: [UUID: AccountUsage] = [:]
        let live = Set(accounts.map(\.id))
        for id in scanners.keys where !live.contains(id) { scanners.removeValue(forKey: id) }

        for account in accounts {
            guard let provider = registry.provider(withID: account.providerID) else {
                result[account.id] = AccountUsage(updatedAt: now, status: .unknownProvider)
                continue
            }
            if let s = scanners[account.id], s.account.dataPath != account.dataPath || s.account.providerID != account.providerID {
                scanners.removeValue(forKey: account.id)
            }
            let scanner = scanners[account.id] ?? AccountScanner(account: account, provider: provider)
            scanners[account.id] = scanner
            result[account.id] = scanner.refresh(now: now, calendar: calendar)
        }
        return result
    }
}
