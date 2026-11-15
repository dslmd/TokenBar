import XCTest
@testable import TokenBarCore

final class PopoverLogicTests: XCTestCase {
    private let now = TestSupport.now
    private func hours(_ h: Double) -> Date { now.addingTimeInterval(h * 3600) }

    // MARK: Screen

    func testScreenFollowsScanAndAccounts() {
        XCTAssertEqual(PopoverScreen.resolve(hasScanned: false, isScanning: true, accountCount: 0, enabledCount: 0), .scanning)
        XCTAssertEqual(PopoverScreen.resolve(hasScanned: true, isScanning: false, accountCount: 0, enabledCount: 0), .noAccounts)
        XCTAssertEqual(PopoverScreen.resolve(hasScanned: true, isScanning: false, accountCount: 2, enabledCount: 0), .allTurnedOff)
        XCTAssertEqual(PopoverScreen.resolve(hasScanned: true, isScanning: true, accountCount: 2, enabledCount: 0), .scanning)
        // A later rescan never hides accounts that are already shown.
        XCTAssertEqual(PopoverScreen.resolve(hasScanned: true, isScanning: true, accountCount: 2, enabledCount: 1), .accounts)
    }

    // MARK: Detail kind

    func testDetailKindPerProvider() {
        let catalog = ProviderCatalog.default
        func kind(_ id: String) -> AccountDetailKind? { catalog.capabilities(of: id).map(AccountDetailKind.init) }
        XCTAssertEqual(kind("claude"), .logsWithQuota)
        XCTAssertEqual(kind("codex"), .logsWithQuota)
        XCTAssertEqual(kind("gemini"), .logsWithQuota)
        XCTAssertEqual(kind(ProviderCatalog.museAIID), .webQuota)
        XCTAssertEqual(kind("muse"), .logsOnly)
        XCTAssertFalse(AccountDetailKind.webQuota.showsTokens)
        XCTAssertFalse(AccountDetailKind.logsOnly.showsQuota)
    }

    // MARK: Quota summary

    func testQuotaSummaryText() {
        let window = QuotaWindow(label: "Weekly", usedPercent: 93.4, resetsAt: hours(2 * 24 + 5))
        let summary = QuotaSummary(window: window, now: now)
        XCTAssertEqual(summary.text, "Weekly 93% · resets in 2 days")
        XCTAssertEqual(summary.level, .critical)
        XCTAssertEqual(summary.fraction, 0.934, accuracy: 0.0001)
        XCTAssertEqual(summary.detailNote, "resets in 2 days")
    }

    func testPercentIsRoundedDownSoItNeverOverstatesTheLevel() {
        let summary = QuotaSummary(window: QuotaWindow(label: "5-hour", usedPercent: 89.7), now: now)
        XCTAssertEqual(summary.percentText, "89%")
        XCTAssertEqual(summary.level, .elevated)
        XCTAssertEqual(summary.text, "5-hour 89%")
        XCTAssertEqual(QuotaSummary(window: QuotaWindow(label: "x", usedPercent: 140), now: now).percent, 100)
    }

    func testStaleWindowHasNoFillAndSaysSo() {
        let summary = QuotaSummary(window: QuotaWindow(label: "5-hour", usedPercent: 18, resetsAt: hours(-1)), now: now)
        XCTAssertEqual(summary.level, .stale)
        XCTAssertEqual(summary.fraction, 0)
        XCTAssertNil(summary.resetPhrase)
        XCTAssertEqual(summary.detailNote, "Window reset, updates after use")
    }

    // MARK: Peak

    func testPeakPicksHighestCurrentWindowAcrossAccounts() {
        let a = UUID(), b = UUID()
        let peak = PeakQuota.find([
            .init(accountID: a, providerName: "Codex", windows: [QuotaWindow(label: "Weekly", usedPercent: 67, resetsAt: hours(100))]),
            .init(accountID: b, providerName: "Claude Code", windows: [
                QuotaWindow(label: "5-hour", usedPercent: 99, resetsAt: hours(-1)),      // reset since: ignored
                QuotaWindow(label: "Weekly", usedPercent: 93, resetsAt: hours(53)),
            ]),
        ], now: now)
        XCTAssertEqual(peak?.accountID, b)
        XCTAssertEqual(peak?.text, "Weekly 93% · Claude Code · resets in 2 days")
    }

    func testPeakIsNilWithoutQuotaAndTiesKeepOrder() {
        XCTAssertNil(PeakQuota.find([.init(accountID: UUID(), providerName: "Muse Code", windows: [])], now: now))
        let first = UUID()
        let tie = PeakQuota.find([
            .init(accountID: first, providerName: "A", windows: [QuotaWindow(label: "Weekly", usedPercent: 50)]),
            .init(accountID: UUID(), providerName: "B", windows: [QuotaWindow(label: "Weekly", usedPercent: 50)]),
        ], now: now)
        XCTAssertEqual(tie?.accountID, first)
    }

    // MARK: Row line

    func testRowLinePriorities() {
        let windows = [QuotaWindow(label: "Weekly", usedPercent: 40, resetsAt: hours(30))]
        // Attention replaces the quota line.
        XCTAssertEqual(AccountRowLine.resolve(.init(kind: .logsWithQuota, hasData: true, attention: "Sign-in expired",
                                                    windows: windows), now: now), .attention("Sign-in expired"))
        XCTAssertEqual(AccountRowLine.resolve(.init(kind: .logsWithQuota, hasData: false), now: now), .reading)
        guard case .quota(let s) = AccountRowLine.resolve(.init(kind: .logsWithQuota, hasData: true, windows: windows), now: now) else {
            return XCTFail("expected a quota line")
        }
        XCTAssertEqual(s.text, "Weekly 40% · resets in 1 day")
        let last = hours(-26)
        XCTAssertEqual(AccountRowLine.resolve(.init(kind: .logsOnly, hasData: true, windows: windows, lastActivity: last), now: now),
                       .lastActive(last))
        XCTAssertEqual(AccountRowLine.resolve(.init(kind: .logsWithQuota, hasData: true, noRecentData: true), now: now), .noRecentUsage)
        XCTAssertEqual(AccountRowLine.resolve(.init(kind: .logsWithQuota, hasData: true), now: now), .none)
        // Online quota off and no window: say so instead of a bare "Last active".
        XCTAssertEqual(AccountRowLine.resolve(.init(kind: .logsWithQuota, hasData: true, onlineQuotaOn: false,
                                                    lastActivity: last), now: now), .onlineQuotaOff)
        // Quota from local logs (Codex) still shows with online quota off.
        if case .quota = AccountRowLine.resolve(.init(kind: .logsWithQuota, hasData: true, onlineQuotaOn: false,
                                                      windows: windows), now: now) {} else { XCTFail("local quota kept") }
        // Muse Code has no quota, so online quota does not matter.
        XCTAssertEqual(AccountRowLine.resolve(.init(kind: .logsOnly, hasData: true, onlineQuotaOn: false, lastActivity: last),
                                              now: now), .lastActive(last))
        // Still reading comes before the quota note.
        XCTAssertEqual(AccountRowLine.resolve(.init(kind: .logsWithQuota, hasData: false, onlineQuotaOn: false), now: now), .reading)
    }

    func testRowLineForWebAccounts() {
        let windows = [QuotaWindow(label: "Weekly", usedPercent: 54, resetsAt: hours(83))]
        XCTAssertEqual(AccountRowLine.resolve(.init(kind: .webQuota, hasData: false, onlineQuotaOn: false), now: now), .onlineQuotaOff)
        XCTAssertEqual(AccountRowLine.resolve(.init(kind: .webQuota, hasData: false), now: now), .reading)
        XCTAssertEqual(AccountRowLine.resolve(.init(kind: .webQuota, hasData: false, attention: "Muse session expired. Sign in again"), now: now),
                       .attention("Muse session expired. Sign in again"))
        guard case .quota(let s) = AccountRowLine.resolve(.init(kind: .webQuota, hasData: true, windows: windows), now: now) else {
            return XCTFail("expected a quota line")
        }
        XCTAssertEqual(s.text, "Weekly 54% · resets in 3 days")
    }

    func testRowLinesForRichDemo() {
        // The demo accounts the overview shows, end to end through the same inputs the app builds.
        let state = DemoScenario.rich.state(now: now, home: "/Users/demo")
        let catalog = ProviderCatalog.default
        var lines: [String: AccountRowLine] = [:]
        for account in state.config.accounts {
            guard let caps = catalog.capabilities(of: account.providerID) else { continue }
            let kind = AccountDetailKind(caps)
            let usage = state.usage[account.id]
            let web = state.webQuota[account.id]
            let windows: [QuotaWindow]
            let attention: String?
            if kind == .webQuota {
                windows = web?.usage?.windows ?? []
                let health = MuseAIAccounts.health(account: account, state: web, onlineQuotaEnabled: true)
                attention = (health.0 == .error || health.0 == .warning) ? health.1 : nil
            } else {
                windows = QuotaMerge.effective(local: usage?.quota, online: state.quota[account.id]?.observation)?.observation.windows ?? []
                let health = AccountHealth.evaluate(account: account, usage: usage, quota: state.quota[account.id])
                attention = (health.0 == .error || health.0 == .warning) ? health.1 : nil
            }
            let input = AccountRowLine.Input(kind: kind, hasData: kind == .webQuota ? web?.usage != nil : usage != nil,
                                             attention: attention, windows: windows, lastActivity: usage?.lastActivity,
                                             noRecentData: usage?.status == .noRecentData)
            lines[account.name + "/" + account.providerID] = AccountRowLine.resolve(input, now: now)
        }
        if case .quota(let s)? = lines["alex@example.com/claude"] { XCTAssertEqual(s.text, "Weekly 93% · resets in 2 days") } else { XCTFail() }
        XCTAssertEqual(lines["sam.rivera@example.com/claude"], .attention("Sign-in expired. Run claude once to renew it"))
        XCTAssertEqual(lines["Muse Free/museai"], .attention("Muse session expired. Sign in again"))
        if case .lastActive? = lines["Default/muse"] {} else { XCTFail("Muse Code shows when it was last active") }
    }

    // MARK: Texts

    func testAgoPhrase() {
        XCTAssertEqual(AgoPhrase.since(now.addingTimeInterval(-20), now: now), "just now")
        XCTAssertEqual(AgoPhrase.since(now.addingTimeInterval(-150), now: now), "2 min ago")
        XCTAssertEqual(AgoPhrase.since(hours(-3.4), now: now), "3 hr ago")
        XCTAssertEqual(AgoPhrase.since(hours(-26), now: now), "1 day ago")
        XCTAssertEqual(AgoPhrase.since(hours(-24 * 5), now: now), "5 days ago")
        // A clock that moved backwards is not "in the future ago".
        XCTAssertEqual(AgoPhrase.since(hours(1), now: now), "just now")
    }

    func testFooterAndSourceTexts() {
        XCTAssertEqual(PopoverText.footer(lastRefresh: nil, now: now), "Reading…")
        XCTAssertEqual(PopoverText.footer(lastRefresh: now.addingTimeInterval(-70), now: now), "Updated 1 min ago")
        let observed = now.addingTimeInterval(-120)
        XCTAssertEqual(PopoverText.quotaSource(kind: .logsWithQuota, isOnline: true, observedAt: observed, now: now),
                       "From online check, 2 min ago")
        XCTAssertEqual(PopoverText.quotaSource(kind: .logsWithQuota, isOnline: false, observedAt: observed, now: now),
                       "From local logs, 2 min ago")
        XCTAssertEqual(PopoverText.quotaSource(kind: .webQuota, isOnline: true, observedAt: observed, now: now),
                       "From muse.ai, 2 min ago")
    }

    func testIdentityLineSkipsTheEmailTheAccountIsNamedAfter() {
        let identity = AccountIdentity(email: "alex@example.com", plan: "max", organization: "Example Labs", isSignedIn: true)
        XCTAssertEqual(PopoverText.identityLine(accountName: "alex@example.com", identity: identity), "Max · Example Labs")
        XCTAssertEqual(PopoverText.identityLine(accountName: "Work", identity: identity), "alex@example.com · Max · Example Labs")
        XCTAssertNil(PopoverText.identityLine(accountName: "alex.dev@example.com",
                                              identity: AccountIdentity(email: "alex.dev@example.com", isSignedIn: true)))
        XCTAssertNil(PopoverText.identityLine(accountName: "x", identity: nil))
    }

    func testPlanAndRenewalLines() {
        XCTAssertEqual(PopoverText.planLine(accountName: "Muse Maximum", planName: "Maximum"), "Maximum plan")
        XCTAssertNil(PopoverText.planLine(accountName: "Muse Free", planName: "Muse Free"))
        XCTAssertNil(PopoverText.planLine(accountName: "Muse", planName: " "))
        XCTAssertEqual(PopoverText.amountLeft("2.8B tokens left"), "2.8B left")
        XCTAssertEqual(PopoverText.amountLeft("$80.00 left"), "$80.00 left")
        XCTAssertEqual(PopoverText.renewal(hours(19 * 24), now: now), "Renews in 19 days")
        XCTAssertNil(PopoverText.renewal(hours(-1), now: now))
        XCTAssertNil(PopoverText.renewal(nil, now: now))
    }

    // MARK: Menu bar label

    func testMenuBarLabelContent() {
        let tokens = MenuBarLabelContent(title: "1.6M", showsNumber: true, warning: false, metric: .tokens, period: .today)
        XCTAssertEqual(tokens.symbolName, "chart.bar.fill")
        XCTAssertEqual(tokens.text, "1.6M")
        XCTAssertEqual(tokens.accessibilityLabel, "TokenBar, 1.6M tokens today")

        let peak = MenuBarLabelContent(title: "93%", showsNumber: true, warning: true, metric: .peakQuota, period: .today)
        XCTAssertEqual(peak.symbolName, "exclamationmark.triangle.fill")
        XCTAssertEqual(peak.accessibilityLabel, "TokenBar, quota almost used up, highest quota 93%")

        let iconOnly = MenuBarLabelContent(title: "1.6M", showsNumber: false, warning: false, metric: .tokens, period: .month)
        XCTAssertNil(iconOnly.text)
        XCTAssertEqual(iconOnly.accessibilityLabel, "TokenBar, 1.6M tokens this month")

        let empty = MenuBarLabelContent(title: "–", showsNumber: true, warning: false, metric: .tokens, period: .today)
        XCTAssertEqual(empty.accessibilityLabel, "TokenBar")
        // No placeholder dash next to the symbol.
        XCTAssertNil(empty.text)
    }

    // MARK: More texts

    func testHeroTokensKeepOneDecimal() {
        XCTAssertEqual(PopoverText.heroTokens(1_996_000), "2.0M")
        XCTAssertEqual(PopoverText.heroTokens(1_540_000), "1.5M")
        XCTAssertEqual(PopoverText.heroTokens(9_800), "9.8K")
        XCTAssertEqual(PopoverText.heroTokens(12_400_000), "12M")
        XCTAssertEqual(PopoverText.heroTokens(999_700), "1.0M")
        XCTAssertEqual(PopoverText.heroTokens(842), "842")
        XCTAssertEqual(PopoverText.heroTokens(0), "0")
    }

    func testListAndNoAccountsText() {
        XCTAssertEqual(PopoverText.list([]), "")
        XCTAssertEqual(PopoverText.list(["A"]), "A")
        XCTAssertEqual(PopoverText.list(["A", "B"]), "A and B")
        XCTAssertEqual(PopoverText.list(["A", "B", "C"]), "A, B and C")
        XCTAssertEqual(PopoverText.noAccounts(localProviders: ["Claude Code", "Codex"], webProviders: ["Muse"]),
                       "TokenBar looks for Claude Code and Codex on this Mac. Sign in to add Muse.")
        XCTAssertEqual(PopoverText.noAccounts(localProviders: ["Codex"], webProviders: []), "TokenBar looks for Codex on this Mac.")
        // Built from the real catalog, so it follows new providers.
        let catalog = ProviderCatalog.default
        let local = catalog.providers.filter { $0.capabilities.localLogs }.map(\.displayName)
        XCTAssertFalse(local.isEmpty)
        XCTAssertTrue(PopoverText.noAccounts(localProviders: local, webProviders: []).contains(local[0]))
    }

    func testSentencesAndMuseProblem() {
        XCTAssertEqual(PopoverText.sentence("Sign-in expired. Run claude once to renew it"), "Sign-in expired. Run claude once to renew it.")
        XCTAssertEqual(PopoverText.sentence("Folder not found."), "Folder not found.")
        XCTAssertEqual(PopoverText.sentence("Updating…"), "Updating…")
        XCTAssertEqual(PopoverText.museProblem(.sessionExpired), "Your Muse session expired.")
        XCTAssertEqual(PopoverText.museProblem(.network), "Network unavailable, will retry later.")
    }
}
