import Foundation

/// Computes the compact menu bar text, kept out of the UI layer so it is testable.
public enum MenuBarSummary {
    public static func tokens(for usage: AccountUsage, period: MenuBarPeriod, includeCache: Bool) -> Int {
        let b: TokenBreakdown
        switch period {
        case .today: b = usage.today
        case .last7Days: b = usage.last7Days
        case .month: b = usage.month
        }
        return includeCache ? b.total : b.totalExcludingCache
    }

    public static func total(accounts: [Account], usage: [UUID: AccountUsage], settings: AppSettings) -> Int {
        accounts
            .filter { settings.menuBarProviderID == nil || $0.providerID == settings.menuBarProviderID }
            .compactMap { usage[$0.id] }
            .reduce(0) { $0 + tokens(for: $1, period: settings.menuBarPeriod, includeCache: settings.menuBarIncludesCache) }
    }

    public static func title(accounts: [Account], usage: [UUID: AccountUsage], settings: AppSettings) -> String {
        if usage.isEmpty { return "–" }
        return TokenFormatter.compact(total(accounts: accounts, usage: usage, settings: settings))
    }
}
