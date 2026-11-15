import Foundation
import XCTest
@testable import TokenBarCore

final class QuotaCacheTests: XCTestCase {
    let now = TestSupport.now
    let a = UUID()
    let b = UUID()

    private func observation(_ percent: Double, at time: Date) -> QuotaObservation {
        QuotaObservation(observedAt: time, windows: [QuotaWindow(label: "Weekly", usedPercent: percent, resetsAt: time.addingTimeInterval(86400))])
    }

    func testFillsOnlyMissingReadingsAndKeepsTheIssue() {
        var cache = QuotaCache()
        cache.record([a: QuotaResult(observation: observation(40, at: now.addingTimeInterval(-3600)))], existing: [a, b], now: now)

        let fresh = observation(55, at: now)
        let filled = cache.filling([a: QuotaResult(issue: .cannotWriteBack(cli: "claude")),
                                    b: QuotaResult(observation: fresh)], now: now)
        XCTAssertEqual(filled[a]?.observation?.windows.first?.usedPercent, 40)
        XCTAssertEqual(filled[a]?.issue, .cannotWriteBack(cli: "claude"), "the remembered reading never hides the reason")
        XCTAssertEqual(filled[b]?.observation, fresh, "a result's own reading wins")
    }

    func testForgetsRemovedAccountsOldReadingsAndIgnoresEmptyOnes() {
        var cache = QuotaCache()
        cache.record([a: QuotaResult(observation: observation(40, at: now)),
                      b: QuotaResult(observation: observation(10, at: now.addingTimeInterval(-9 * 86400)))], existing: [a, b], now: now)
        XCTAssertEqual(Set(cache.entries.keys), [a], "readings older than eight days are dropped")

        cache.record([a: QuotaResult(observation: QuotaObservation(observedAt: now, windows: []))], existing: [a], now: now)
        XCTAssertEqual(cache.entries[a]?.windows.first?.usedPercent, 40, "an empty reading does not replace a real one")

        cache.record([:], existing: [], now: now)
        XCTAssertTrue(cache.entries.isEmpty)
    }

    func testRoundTripOnDisk() throws {
        var cache = QuotaCache()
        cache.record([a: QuotaResult(observation: observation(62.5, at: now))], existing: [a], now: now)
        let url = try TestSupport.tempDir().appendingPathComponent("quota-cache.json")
        try cache.save(to: url)
        XCTAssertEqual(QuotaCache.load(from: url), cache)
        XCTAssertEqual(QuotaCache.load(from: url.appendingPathExtension("missing")), QuotaCache())
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("token"), "only percentages and times are stored")
    }

    func testRenewalWaitIsRoutine() {
        XCTAssertTrue(QuotaIssue.cannotWriteBack(cli: "claude").isAwaitingCLIRenewal)
        XCTAssertFalse(QuotaIssue.loginExpired(cli: "claude").isAwaitingCLIRenewal)
        let account = Account(providerID: "claude", name: "a", dataPath: "~/.claude")
        let usage = AccountUsage(updatedAt: now, status: .ok)
        XCTAssertEqual(AccountHealth.evaluate(account: account, usage: usage, quota: QuotaResult(issue: .cannotWriteBack(cli: "claude"))).0, .ok)
        XCTAssertEqual(AccountHealth.evaluate(account: account, usage: usage, quota: QuotaResult(issue: .loginExpired(cli: "claude"))).0, .warning)
        XCTAssertEqual(AccountRowLine.resolve(.init(kind: .logsWithQuota, hasData: true, quotaNote: "Quota updates after claude renews its sign-in."), now: now),
                       .note("Quota updates after claude renews its sign-in."))
    }

    func testPlanLabelsAndPersonalOrganization() {
        XCTAssertEqual(AccountIdentity(plan: "prolite").planLabel, "Pro Lite")
        XCTAssertEqual(AccountIdentity(plan: "plus").planLabel, "Plus")
        XCTAssertEqual(AccountIdentity(plan: "max_5x").planLabel, "Max 5x")
        XCTAssertNil(AccountIdentity.meaningfulOrganization("me@example.com's Organization", email: "me@example.com"))
        XCTAssertNil(AccountIdentity.meaningfulOrganization("ME@example.com's organization", email: "me@example.com"))
        XCTAssertEqual(AccountIdentity.meaningfulOrganization("Example Labs", email: "me@example.com"), "Example Labs")
        XCTAssertNil(AccountIdentity.meaningfulOrganization("  ", email: nil))
    }
}
