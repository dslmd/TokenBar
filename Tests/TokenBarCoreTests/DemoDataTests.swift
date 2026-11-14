import XCTest
@testable import TokenBarCore

final class DemoDataTests: XCTestCase {
    private let home = "/Users/demo"

    func testEveryScenarioIsConsistent() {
        let catalog = ProviderCatalog.default
        for scenario in DemoScenario.allCases {
            let state = scenario.state(now: TestSupport.now, home: home)
            let ids = Set(state.config.accounts.map(\.id))
            XCTAssertEqual(ids.count, state.config.accounts.count, "\(scenario): duplicate ids")
            for account in state.config.accounts {
                XCTAssertNotNil(catalog.info(for: account.providerID), "\(scenario): unknown provider \(account.providerID)")
                if account.name.contains("@") { XCTAssertTrue(account.name.hasSuffix("@example.com")) }
            }
            for id in Array(state.usage.keys) + Array(state.quota.keys) + Array(state.identities.keys) + Array(state.webQuota.keys) {
                XCTAssertTrue(ids.contains(id), "\(scenario): state for an account that does not exist")
            }
            for identity in state.identities.values {
                if let email = identity.email { XCTAssertTrue(email.hasSuffix("@example.com")) }
            }
            for usage in state.usage.values {
                XCTAssertEqual(usage.daily.count, 7)
                XCTAssertEqual(usage.daily.last?.tokens, usage.today)
                XCTAssertEqual(usage.daily.reduce(TokenBreakdown.zero) { $0 + $1.tokens }, usage.last7Days)
                XCTAssertGreaterThanOrEqual(usage.month.total, usage.last7Days.total)
            }
        }
    }

    func testRichScenarioCoversTheInterestingStates() {
        let state = DemoScenario.rich.state(now: TestSupport.now, home: home)
        let accounts = state.config.accounts
        func count(_ provider: String) -> Int { accounts.filter { $0.providerID == provider }.count }
        XCTAssertEqual(count("claude"), 2)
        XCTAssertEqual(count("codex"), 1)
        XCTAssertEqual(count("gemini"), 1)
        XCTAssertEqual(count(ProviderCatalog.museAIID), 2)
        XCTAssertEqual(count("muse"), 1)

        // One Claude account is above the menu bar warning threshold, the other has an expired sign-in.
        let peak = QuotaMerge.peakPercent(accounts: accounts, usage: state.usage, quota: state.quota, now: TestSupport.now)
        XCTAssertEqual(peak, 93)
        XCTAssertEqual(state.quota[DemoID.claudeWork]?.issue, .loginExpired(cli: "claude"))
        XCTAssertEqual(state.usage[DemoID.codex]?.quota?.windows.count, 2)
        XCTAssertTrue(MuseAIAccounts.needsSignIn(state.webQuota[DemoID.museFree]))
        XCTAssertFalse(MuseAIAccounts.needsSignIn(state.webQuota[DemoID.museMax]))
        XCTAssertEqual(MenuBarSummary.title(accounts: accounts, usage: state.usage, settings: state.config.settings), "2M")
    }

    func testEmptyAndOffScenarios() {
        XCTAssertTrue(DemoScenario.empty.state(now: TestSupport.now, home: home).config.accounts.isEmpty)
        XCTAssertFalse(DemoScenario.scanning.state(now: TestSupport.now, home: home).hasScanned)
        let off = DemoScenario.allOff.state(now: TestSupport.now, home: home)
        XCTAssertFalse(off.config.accounts.isEmpty)
        XCTAssertTrue(off.config.accounts.allSatisfy { !$0.isEnabled })
        XCTAssertEqual(DemoScenario.sparse.state(now: TestSupport.now, home: home).config.accounts.count, 1)
    }

    func testDemoLoginDriverTouchesNothing() {
        let driver = DemoLoginDriver(managedRootPath: "/Users/demo/managed")
        XCTAssertNil(driver.unavailableReason(providerID: "claude"))
        XCTAssertNotNil(driver.unavailableReason(providerID: "muse"))
        XCTAssertTrue(driver.isManagedHome("/Users/demo/managed/claude/x"))
        XCTAssertFalse(driver.isManagedHome("/Users/demo/.claude"))
        XCTAssertNil(driver.shellAlias(providerID: "claude", homePath: "/Users/demo/managed/claude/x"))
    }
}
