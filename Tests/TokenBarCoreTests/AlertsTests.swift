import Foundation
import XCTest
@testable import TokenBarCore

final class QuotaAlertsTests: XCTestCase {
    let now = TestSupport.now
    let account = Account(providerID: "claude", name: "alex@example.com", dataPath: "~/.claude")

    private func input(_ windows: [QuotaWindow], problem: String? = nil, known: Bool = true) -> QuotaAlerts.Input {
        QuotaAlerts.Input(account: account, providerName: "Claude Code", windows: windows, signInProblem: problem, isKnown: known)
    }

    private func plan(_ inputs: [QuotaAlerts.Input], settings: AppSettings = AppSettings(), ledger: [String] = [],
                      at time: Date? = nil) -> (alerts: [PendingAlert], ledger: [String]) {
        QuotaAlerts.plan(inputs: inputs, settings: settings, ledger: ledger, existingAccountIDs: [account.id], now: time ?? now)
    }

    func testQuotaAlertFiresOncePerCycleAndAgainAfterReset() {
        let reset = now.addingTimeInterval(2 * 86400)
        let weekly = QuotaWindow(label: "Weekly", usedPercent: 93.4, resetsAt: reset)

        let first = plan([input([weekly])])
        XCTAssertEqual(first.alerts.count, 1)
        XCTAssertEqual(first.alerts[0].title, "Weekly quota at 93%")
        XCTAssertEqual(first.alerts[0].subtitle, "Claude Code · alex@example.com")
        XCTAssertEqual(first.alerts[0].body, "Resets in 2 days.")

        // Same cycle, higher usage: no repeat.
        let again = plan([input([QuotaWindow(label: "Weekly", usedPercent: 97, resetsAt: reset)])], ledger: first.ledger)
        XCTAssertTrue(again.alerts.isEmpty)

        // After the reset the old entry is dropped and the next cycle alerts again.
        let later = reset.addingTimeInterval(3 * 86400)
        let next = QuotaWindow(label: "Weekly", usedPercent: 91, resetsAt: later.addingTimeInterval(4 * 86400))
        let afterReset = plan([input([next])], ledger: again.ledger, at: later)
        XCTAssertEqual(afterReset.alerts.count, 1)
        XCTAssertFalse(afterReset.ledger.contains(first.ledger[0]))
    }

    func testBelowThresholdStaleAndTurnedOffDoNotAlert() {
        let reset = now.addingTimeInterval(3600)
        XCTAssertTrue(plan([input([QuotaWindow(label: "5-hour", usedPercent: 89.9, resetsAt: reset)])]).alerts.isEmpty)
        let stale = QuotaWindow(label: "5-hour", usedPercent: 99, resetsAt: now.addingTimeInterval(-60))
        XCTAssertTrue(plan([input([stale])]).alerts.isEmpty)

        var off = AppSettings()
        off.quotaAlertThreshold = nil
        let result = plan([input([QuotaWindow(label: "5-hour", usedPercent: 99, resetsAt: reset)])], settings: off)
        XCTAssertTrue(result.alerts.isEmpty)
        XCTAssertTrue(result.ledger.isEmpty, "Nothing is remembered while alerts are off, so turning them on alerts right away")
    }

    func testCustomThreshold() {
        var settings = AppSettings()
        settings.quotaAlertThreshold = 75
        let window = QuotaWindow(label: "Pro", usedPercent: 76, resetsAt: now.addingTimeInterval(9 * 3600))
        let result = plan([input([window])], settings: settings)
        XCTAssertEqual(result.alerts.map(\.body), ["Resets in 9 hr."])
    }

    func testWindowWithoutResetRearmsWhenUsageFallsClearlyBelow() {
        let high = QuotaWindow(label: "Weekly", usedPercent: 95)
        let first = plan([input([high])])
        XCTAssertEqual(first.alerts.count, 1)
        XCTAssertEqual(first.alerts[0].body, "TokenBar shows the details in the menu bar.")

        // Slightly below the threshold: still remembered.
        let slightly = plan([input([QuotaWindow(label: "Weekly", usedPercent: 85)])], ledger: first.ledger)
        XCTAssertEqual(slightly.ledger, first.ledger)
        // Clearly below: forgotten, and the next rise alerts again.
        let low = plan([input([QuotaWindow(label: "Weekly", usedPercent: 40)])], ledger: slightly.ledger)
        XCTAssertTrue(low.ledger.isEmpty)
        XCTAssertEqual(plan([input([high])], ledger: low.ledger).alerts.count, 1)
    }

    func testSignInAlertFiresOnceAndClearsOnlyWhenKnownHealthy() {
        let first = plan([input([], problem: "Sign-in expired. Run claude once to renew it")])
        XCTAssertEqual(first.alerts.count, 1)
        XCTAssertEqual(first.alerts[0].title, "Sign-in needs attention")
        XCTAssertEqual(first.alerts[0].body, "Sign-in expired. Run claude once to renew it.")

        XCTAssertTrue(plan([input([], problem: "Sign-in expired. Run claude once to renew it")], ledger: first.ledger).alerts.isEmpty)
        // Not read yet: keep the memory.
        XCTAssertEqual(plan([input([], known: false)], ledger: first.ledger).ledger, first.ledger)
        // Read and fine: forget, so a later expiry alerts again.
        XCTAssertTrue(plan([input([])], ledger: first.ledger).ledger.isEmpty)

        var off = AppSettings()
        off.signInAlertsEnabled = false
        XCTAssertTrue(plan([input([], problem: "Expired")], settings: off).alerts.isEmpty)
    }

    func testLedgerDropsRemovedAccountsDuplicatesAndGarbage() {
        let other = UUID()
        let reset = now.addingTimeInterval(86400)
        let window = QuotaWindow(label: "Weekly", usedPercent: 10, resetsAt: reset)
        let mine = QuotaAlerts.quotaKey(account: account.id, window: window)
        let ledger = [mine, mine, QuotaAlerts.signInKey(account: other), "nonsense", "q|bad"]
        XCTAssertEqual(plan([input([window])], ledger: ledger).ledger, [mine])
    }

    func testSignInProblemOnlyForIssuesTheUserFixes() {
        XCTAssertEqual(QuotaAlerts.signInProblem(for: .loginExpired(cli: "claude")), "Sign-in expired. Run claude once to renew it.")
        XCTAssertNotNil(QuotaAlerts.signInProblem(for: .accessDenied))
        for issue: QuotaIssue? in [nil, .network, .server(500), .disabled, .unsupported, .notSignedIn, .other, .cannotWriteBack(cli: "claude")] {
            XCTAssertNil(QuotaAlerts.signInProblem(for: issue))
        }
    }
}

final class QuotaLevelTests: XCTestCase {
    func testLevels() {
        XCTAssertEqual(QuotaLevel(percent: 0), .normal)
        XCTAssertEqual(QuotaLevel(percent: 74.9), .normal)
        XCTAssertEqual(QuotaLevel(percent: 75), .elevated)
        XCTAssertEqual(QuotaLevel(percent: 89.9), .elevated)
        XCTAssertEqual(QuotaLevel(percent: 90), .critical)
        let now = TestSupport.now
        XCTAssertEqual(QuotaLevel(window: QuotaWindow(label: "W", usedPercent: 95, resetsAt: now.addingTimeInterval(-1)), now: now), .stale)
    }

    func testPeakWindowIgnoresStaleWindows() {
        let now = TestSupport.now
        let windows = [
            QuotaWindow(label: "5-hour", usedPercent: 99, resetsAt: now.addingTimeInterval(-10)),
            QuotaWindow(label: "Weekly", usedPercent: 60, resetsAt: now.addingTimeInterval(10)),
            QuotaWindow(label: "Opus", usedPercent: 71),
        ]
        XCTAssertEqual(QuotaMerge.peakWindow(windows, now: now)?.label, "Opus")
        XCTAssertNil(QuotaMerge.peakWindow([], now: now))
    }

    func testResetPhrase() {
        let now = TestSupport.now
        XCTAssertEqual(ResetPhrase.until(now.addingTimeInterval(30), now: now), "in less than a minute")
        XCTAssertEqual(ResetPhrase.until(now.addingTimeInterval(25 * 60), now: now), "in 25 min")
        XCTAssertEqual(ResetPhrase.until(now.addingTimeInterval(3 * 3600 + 600), now: now), "in 3 hr")
        XCTAssertEqual(ResetPhrase.until(now.addingTimeInterval(30 * 3600), now: now), "in 1 day")
        XCTAssertEqual(ResetPhrase.until(now.addingTimeInterval(6 * 86400), now: now), "in 6 days")
    }
}

final class NewSettingsTests: XCTestCase {
    func testOldConfigGetsDefaults() throws {
        let json = #"{"refreshIntervalSeconds": 120, "menuBarPeriod": "month"}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.refreshIntervalSeconds, 120)
        XCTAssertEqual(s.menuBarPeriod, .month)
        XCTAssertEqual(s.menuBarMetric, .tokens)
        XCTAssertFalse(s.hasCompletedOnboarding)
        XCTAssertEqual(s.quotaAlertThreshold, 90)
        XCTAssertTrue(s.signInAlertsEnabled)
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"accounts": []}"#.utf8))
        XCTAssertEqual(config.alertLedger, [])
    }

    func testRoundTripIncludingAlertsOff() throws {
        var s = AppSettings()
        s.menuBarMetric = .peakQuota
        s.hasCompletedOnboarding = true
        s.quotaAlertThreshold = nil
        s.signInAlertsEnabled = false
        s.menuBarProviderID = "codex"
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(decoded, s)

        s.quotaAlertThreshold = 75
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s)), s)

        var config = AppConfig(settings: s)
        config.alertLedger = ["s|\(UUID().uuidString)"]
        XCTAssertEqual(try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config)), config)
    }

    func testOutOfRangeThresholdMeansOff() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"quotaAlertThreshold": 250}"#.utf8))
        XCTAssertNil(s.quotaAlertThreshold)
    }

    func testMenuBarTitleForPeakQuota() {
        var settings = AppSettings()
        settings.menuBarMetric = .peakQuota
        XCTAssertEqual(MenuBarSummary.title(accounts: [], usage: [:], settings: settings, peakQuotaPercent: 93.7), "93%")
        XCTAssertEqual(MenuBarSummary.title(accounts: [], usage: [:], settings: settings, peakQuotaPercent: 140), "100%")
        XCTAssertEqual(MenuBarSummary.title(accounts: [], usage: [:], settings: settings, peakQuotaPercent: nil), "–")
        settings.menuBarMetric = .tokens
        XCTAssertEqual(MenuBarSummary.title(accounts: [], usage: [:], settings: settings, peakQuotaPercent: 93.7), "–")
    }
}
