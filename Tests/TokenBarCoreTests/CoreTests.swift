import XCTest
@testable import TokenBarCore

final class CoreTests: XCTestCase {
    func testCompactFormatting() {
        XCTAssertEqual(TokenFormatter.compact(0), "0")
        XCTAssertEqual(TokenFormatter.compact(999), "999")
        XCTAssertEqual(TokenFormatter.compact(1_000), "1K")
        XCTAssertEqual(TokenFormatter.compact(1_234), "1.2K")
        XCTAssertEqual(TokenFormatter.compact(12_345), "12K")
        XCTAssertEqual(TokenFormatter.compact(999_999), "1M")
        XCTAssertEqual(TokenFormatter.compact(1_234_567), "1.2M")
        XCTAssertEqual(TokenFormatter.compact(250_000_000), "250M")
        XCTAssertEqual(TokenFormatter.compact(3_400_000_000), "3.4B")
        XCTAssertEqual(TokenFormatter.grouped(1234567), "1,234,567")
    }

    func testISO8601Parsing() {
        XCTAssertEqual(ISO8601.parse("2025-10-15T12:00:00Z")?.timeIntervalSince1970, 1_760_529_600)
        XCTAssertEqual(ISO8601.parse("2025-10-15T12:00:00.250Z")?.timeIntervalSince1970 ?? 0, 1_760_529_600.25, accuracy: 0.0001)
        XCTAssertEqual(ISO8601.parse("2025-10-15T20:00:00+08:00")?.timeIntervalSince1970, 1_760_529_600)
        XCTAssertEqual(ISO8601.parse("2025-10-15T12:00:00")?.timeIntervalSince1970, 1_760_529_600)
        XCTAssertEqual(ISO8601.parse("1970-01-01T00:00:00Z")?.timeIntervalSince1970, 0)
        XCTAssertEqual(ISO8601.parse("2024-02-29T00:00:00Z")?.timeIntervalSince1970, 1_709_164_800)
        XCTAssertNil(ISO8601.parse("garbage"))
        XCTAssertNil(ISO8601.parse("2025-13-15T12:00:00Z"))
        XCTAssertNil(ISO8601.parse(""))
    }

    func testPeriodsInNonUTCTimezone() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        // 2025-10-15T20:00+08:00 => today starts 2025-10-15T00:00+08:00
        let now = ISO8601.parse("2025-10-15T20:00:00+08:00")!
        let p = Periods(now: now, calendar: cal)
        XCTAssertEqual(p.todayStart, ISO8601.parse("2025-10-15T00:00:00+08:00"))
        XCTAssertEqual(p.weekStart, ISO8601.parse("2025-10-09T00:00:00+08:00"))
        XCTAssertEqual(p.monthStart, ISO8601.parse("2025-10-01T00:00:00+08:00"))
    }

    func testConfigRoundTripAndTolerantDecoding() throws {
        let dir = try TestSupport.tempDir()
        let store = ConfigStore(url: dir.appendingPathComponent("sub/config.json"))
        XCTAssertNil(store.load())
        let cfg = AppConfig(accounts: [Account(providerID: "claude", name: "Work", dataPath: "~/.claude-work")],
                            settings: AppSettings(refreshIntervalSeconds: 30, menuBarProviderID: "codex", menuBarPeriod: .month, menuBarIncludesCache: true))
        try store.save(cfg)
        XCTAssertEqual(store.load(), cfg)

        // Unknown keys / missing keys / bad values fall back to defaults instead of failing.
        try Data("{\"settings\":{\"refreshIntervalSeconds\":\"x\",\"menuBarPeriod\":\"bogus\",\"future\":1},\"accounts\":[]}".utf8)
            .write(to: store.url)
        XCTAssertEqual(store.load()?.settings, AppSettings())
    }

    func testCorruptConfigIsMovedAside() throws {
        let dir = try TestSupport.tempDir()
        let url = dir.appendingPathComponent("config.json")
        try Data("{not json".utf8).write(to: url)
        let store = ConfigStore(url: url)
        XCTAssertNil(store.load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testConfigFileContainsNoSecrets() throws {
        let dir = try TestSupport.tempDir()
        let store = ConfigStore(url: dir.appendingPathComponent("config.json"))
        let secrets = InMemorySecretStore()
        let acct = Account(providerID: "muse", name: "m", dataPath: "/x")
        try secrets.setSecret("sk-super-secret", for: acct.id)
        try store.save(AppConfig(accounts: [acct]))
        let text = try String(contentsOf: store.url, encoding: .utf8)
        XCTAssertFalse(text.contains("sk-super-secret"))
        XCTAssertEqual(secrets.secret(for: acct.id), "sk-super-secret")
    }

    func testMenuBarSummary() {
        let a = Account(providerID: "claude", name: "a", dataPath: "")
        let b = Account(providerID: "codex", name: "b", dataPath: "")
        let now = TestSupport.now
        let usage: [UUID: AccountUsage] = [
            a.id: AccountUsage(today: TokenBreakdown(input: 1_000_000, output: 200_000, cacheRead: 5_000_000, cacheWrite: 0), updatedAt: now),
            b.id: AccountUsage(today: TokenBreakdown(input: 100_000, output: 0, cacheRead: 0, cacheWrite: 0), updatedAt: now),
        ]
        var s = AppSettings()
        XCTAssertEqual(MenuBarSummary.title(accounts: [a, b], usage: usage, settings: s), "1.3M")
        s.menuBarIncludesCache = true
        XCTAssertEqual(MenuBarSummary.title(accounts: [a, b], usage: usage, settings: s), "6.3M")
        s.menuBarProviderID = "codex"
        XCTAssertEqual(MenuBarSummary.title(accounts: [a, b], usage: usage, settings: s), "100K")
        XCTAssertEqual(MenuBarSummary.title(accounts: [a], usage: [:], settings: s), "–")
    }

    func testRegistryProvidesAllProviders() {
        XCTAssertEqual(ProviderRegistry.default.providers.map(\.id), ["claude", "codex", "gemini", "muse"])
        XCTAssertTrue(ProviderRegistry.default.providers.allSatisfy { !$0.supportsAPIKey })
    }
}
