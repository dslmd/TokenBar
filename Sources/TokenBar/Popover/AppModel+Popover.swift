import Foundation
import TokenBarCore

/// What the menu bar window needs from the model, built from the shared model API.
extension AppModel {
    var popoverScreen: PopoverScreen {
        PopoverScreen.resolve(hasScanned: hasScanned, isScanning: isScanning,
                              accountCount: accounts.count, enabledCount: enabledAccounts.count)
    }

    func popoverAccount(withID id: UUID) -> Account? {
        enabledAccounts.first { $0.id == id }
    }

    func providerName(of account: Account) -> String {
        catalog.info(for: account.providerID)?.displayName ?? account.providerID
    }

    func detailKind(for account: Account) -> AccountDetailKind {
        capabilities(of: account.providerID).map(AccountDetailKind.init) ?? .logsOnly
    }

    /// The second line of an account's row in the overview.
    func rowLine(for account: Account, now: Date) -> AccountRowLine {
        let kind = detailKind(for: account)
        let usage = usage[account.id]
        let hasData = kind == .webQuota ? webQuota[account.id]?.usage != nil : usage != nil
        let input = AccountRowLine.Input(kind: kind, hasData: hasData, attention: attentionMessage(for: account),
                                         onlineQuotaOn: onlineQuotaIsOn(for: account),
                                         windows: quotaWindows(for: account).windows,
                                         lastActivity: usage?.lastActivity, noRecentData: usage?.status == .noRecentData)
        return AccountRowLine.resolve(input, now: now)
    }

    /// The quota window closest to running out over every account that is turned on.
    func peakQuota(now: Date) -> PeakQuota? {
        PeakQuota.find(enabledAccounts.map {
            PeakQuota.Candidate(accountID: $0.id, providerName: providerName(of: $0), windows: quotaWindows(for: $0).windows)
        }, now: now)
    }

    /// Today's tokens of some accounts; nil while none of them has been read.
    func todayTokens(of accounts: [Account]) -> Int? {
        let read = accounts.compactMap { usage[$0.id] }
        guard !read.isEmpty else { return nil }
        return read.reduce(0) { $0 + displayTotal($1.today) }
    }

    /// Today's total for the header; nil while nothing has been read (or no account has token counts).
    var heroTodayTokens: Int? { todayTokens(of: enabledAccounts) }
}
