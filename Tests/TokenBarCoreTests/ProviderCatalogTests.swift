import Foundation
import XCTest
@testable import TokenBarCore

final class ProviderCatalogTests: XCTestCase {
    let catalog = ProviderCatalog.default

    func testOrderAndCapabilities() {
        XCTAssertEqual(catalog.providers.map(\.id), ["claude", "codex", "gemini", "museai", "muse"])
        XCTAssertEqual(catalog.providers.map(\.displayName), ["Claude Code", "Codex", "Gemini CLI", "Muse", "Muse Code"])

        let muse = try! XCTUnwrap(catalog.info(for: "museai"))
        XCTAssertEqual(muse.capabilities, ProviderCapabilities(localLogs: false, folderAccounts: false, signIn: .web, onlineQuota: .webSession))
        XCTAssertNil(muse.usageProvider)
        XCTAssertNil(muse.dataPathHint)
        XCTAssertNotNil(muse.note)

        for id in ["claude", "codex", "gemini"] {
            XCTAssertEqual(catalog.capabilities(of: id),
                           ProviderCapabilities(localLogs: true, folderAccounts: true, signIn: .cli, onlineQuota: .cliCredentials), id)
        }
        let museCode = try! XCTUnwrap(catalog.info(for: "muse"))
        XCTAssertEqual(museCode.capabilities.signIn, .none)
        XCTAssertFalse(museCode.capabilities.hasOnlineQuota)
        XCTAssertNotNil(museCode.signInUnavailableText)
        XCTAssertNil(catalog.info(for: "future-provider"))
        XCTAssertEqual(catalog.menuBarProviders.map(\.id), ["claude", "codex", "gemini", "muse"])
    }

    func testCatalogAgreesWithRegistryQuotaServiceAndDiscovery() {
        // Every log parser is listed, and only log providers have one.
        for p in ProviderRegistry.default.providers { XCTAssertEqual(catalog.info(for: p.id)?.capabilities.localLogs, true, p.id) }
        for info in catalog.providers { XCTAssertEqual(info.usageProvider != nil, info.capabilities.localLogs, info.id) }
        XCTAssertEqual(Set(catalog.providers.filter { $0.capabilities.onlineQuota == .cliCredentials }.map(\.id)),
                       QuotaService.supportedProviderIDs)
        // Muse has no log directory, no detection rule and no CLI sign-in.
        XCTAssertNil(ProviderRegistry.default.provider(withID: "museai"))
        XCTAssertNil(ProviderHomeRule.rule(for: "museai"))
        for info in catalog.providers where info.capabilities.folderAccounts {
            XCTAssertNotNil(ProviderHomeRule.rule(for: info.id), info.id)
        }
    }

    func testAccountRouting() {
        let claude = Account(providerID: "claude", name: "c", dataPath: "/c")
        let museCode = Account(providerID: "muse", name: "m", dataPath: "/m")
        let web = Account(providerID: "museai", name: "Muse", dataPath: "")
        let webOff = Account(providerID: "museai", name: "Muse 2", dataPath: "", onlineQuotaEnabled: false)
        let webDisabled = Account(providerID: "museai", name: "Muse 3", dataPath: "", isEnabled: false)
        let unknown = Account(providerID: "future-provider", name: "f", dataPath: "/f")
        let all = [claude, museCode, web, webOff, webDisabled, unknown]

        XCTAssertEqual(catalog.logAccounts(all).map(\.id), [claude.id, museCode.id])
        XCTAssertEqual(catalog.cliQuotaAccounts(all).map(\.id), [claude.id])
        XCTAssertEqual(catalog.webQuotaTargets(all, onlineQuotaEnabled: true), [web.id])
        XCTAssertEqual(catalog.webQuotaTargets(all, onlineQuotaEnabled: false), [], "global switch off: no calls at all")
    }

    func testConfigWithMuseAndUnknownProvidersLoadsAndRoundTrips() throws {
        let json = """
        {"version":1,"accounts":[
          {"id":"11111111-2222-3333-4444-555555555551","providerID":"museai","name":"Muse Power","dataPath":"","origin":"signedIn"},
          {"id":"11111111-2222-3333-4444-555555555552","providerID":"museai","name":"Muse Power 2","dataPath":"","origin":"signedIn","onlineQuotaEnabled":false},
          {"id":"11111111-2222-3333-4444-555555555553","providerID":"from-the-future","name":"x","dataPath":"","origin":"someNewOrigin"}]}
        """
        let dir = try TestSupport.tempDir()
        let store = ConfigStore(url: dir.appendingPathComponent("config.json"))
        try Data(json.utf8).write(to: store.url)
        let cfg = try XCTUnwrap(store.load())
        XCTAssertEqual(cfg.accounts.map(\.name), ["Muse Power", "Muse Power 2", "x"])
        XCTAssertNil(cfg.accounts[2].origin, "an unknown origin does not drop the account")
        try store.save(cfg)
        XCTAssertEqual(store.load(), cfg)
        // Nothing reads logs or online quota for unknown providers.
        XCTAssertEqual(ProviderCatalog.default.logAccounts(cfg.accounts), [])
        XCTAssertEqual(ProviderCatalog.default.cliQuotaAccounts(cfg.accounts), [])
        XCTAssertEqual(ProviderCatalog.default.webQuotaTargets(cfg.accounts, onlineQuotaEnabled: true), [cfg.accounts[0].id])
    }
}

final class MuseAIAccountsTests: XCTestCase {
    func testDefaultNamesAreDistinguishable() {
        XCTAssertEqual(MuseAIAccounts.defaultName(accountLabel: nil, planName: "Power", existingNames: []), "Muse Power")
        XCTAssertEqual(MuseAIAccounts.defaultName(accountLabel: nil, planName: "Power", existingNames: ["Muse Power"]), "Muse Power 2")
        XCTAssertEqual(MuseAIAccounts.defaultName(accountLabel: nil, planName: "Power", existingNames: ["muse power", "Muse Power 2"]), "Muse Power 3")
        XCTAssertEqual(MuseAIAccounts.defaultName(accountLabel: nil, planName: "Muse Free", existingNames: []), "Muse Free")
        XCTAssertEqual(MuseAIAccounts.defaultName(accountLabel: nil, planName: nil, existingNames: ["Muse"]), "Muse 2")
        XCTAssertEqual(MuseAIAccounts.defaultName(accountLabel: " ", planName: "  ", existingNames: []), "Muse")
        XCTAssertEqual(MuseAIAccounts.defaultName(accountLabel: "me@example.com", planName: "Power", existingNames: []), "me@example.com")
    }

    private func usage(_ percent: Double, resets: Date) -> MuseAIUsage {
        MuseAIUsage(planName: "Power", windows: [QuotaWindow(label: "Weekly", usedPercent: percent, windowMinutes: 10080, resetsAt: resets)],
                    tokensLeft: "2.8B tokens left", topUp: MuseAITopUp(label: "Additional tokens", value: "1.5B tokens left", usedFraction: 0.25),
                    renewsAt: nil, observedAt: TestSupport.now)
    }

    func testHealth() {
        let a = Account(providerID: "museai", name: "Muse", dataPath: "")
        let good = MuseAIService.State(usage: usage(3, resets: TestSupport.now.addingTimeInterval(3600)))
        XCTAssertEqual(MuseAIAccounts.health(account: a, state: good, onlineQuotaEnabled: true).0, .ok)
        XCTAssertEqual(MuseAIAccounts.health(account: a, state: nil, onlineQuotaEnabled: true).0, .unknown)
        XCTAssertEqual(MuseAIAccounts.health(account: a, state: good, onlineQuotaEnabled: false).0, .unknown)
        var off = a
        off.isEnabled = false
        XCTAssertEqual(MuseAIAccounts.health(account: off, state: good, onlineQuotaEnabled: true).0, .disabled)

        let expired = MuseAIService.State(usage: good.usage, failure: .sessionExpired)
        XCTAssertEqual(MuseAIAccounts.health(account: a, state: expired, onlineQuotaEnabled: true).0, .error)
        XCTAssertEqual(MuseAIAccounts.health(account: a, state: expired, onlineQuotaEnabled: true).1, MuseAIFailure.sessionExpired.message)
        XCTAssertTrue(MuseAIAccounts.needsSignIn(expired))
        XCTAssertTrue(MuseAIAccounts.needsSignIn(MuseAIService.State(failure: .signedOut)))
        for f in [MuseAIFailure.siteChanged, .network, .server(502)] {
            XCTAssertEqual(MuseAIAccounts.health(account: a, state: MuseAIService.State(failure: f), onlineQuotaEnabled: true).0, .warning)
            XCTAssertFalse(MuseAIAccounts.needsSignIn(MuseAIService.State(failure: f)))
        }
        XCTAssertFalse(MuseAIAccounts.needsSignIn(nil))
    }

    func testDetailLines() {
        let u = usage(3, resets: TestSupport.now)
        XCTAssertEqual(u.detailLines, ["2.8B tokens left", "Additional tokens: 1.5B tokens left"])
        let free = MuseAIUsage(planName: "Muse Free", windows: [], tokensLeft: nil, topUp: nil, renewsAt: nil, observedAt: TestSupport.now)
        XCTAssertEqual(free.detailLines, [])
    }

    func testMuseQuotaRaisesMenuBarWarningButAddsNoTokens() {
        let claude = Account(providerID: "claude", name: "c", dataPath: "/c")
        let muse = Account(providerID: "museai", name: "Muse", dataPath: "")
        let now = TestSupport.now
        let usageMap = [claude.id: AccountUsage(today: TokenBreakdown(input: 1000, output: 500), updatedAt: now)]
        let states = [muse.id: MuseAIService.State(usage: usage(95, resets: now.addingTimeInterval(3600)))]
        let quota = MuseAIAccounts.quotaResults(states)
        XCTAssertEqual(QuotaMerge.peakPercent(accounts: [claude, muse], usage: usageMap, quota: quota, now: now), 95)
        XCTAssertEqual(MenuBarSummary.total(accounts: [claude, muse], usage: usageMap, settings: AppSettings()), 1500)
        // A window that already reset does not warn; failed reads without usage contribute nothing.
        let stale = [muse.id: MuseAIService.State(usage: usage(95, resets: now.addingTimeInterval(-1)))]
        XCTAssertNil(QuotaMerge.peakPercent(accounts: [muse], usage: [:], quota: MuseAIAccounts.quotaResults(stale), now: now))
        XCTAssertTrue(MuseAIAccounts.quotaResults([muse.id: MuseAIService.State(failure: .network)]).isEmpty)
    }
}

// MARK: - Reconciliation with folder-less accounts and exact managed paths

final class ReconcilerMuseAndManagedPathTests: XCTestCase {
    var home: URL!
    var fs: LocalFileSystem!

    override func setUpWithError() throws {
        home = try TestSupport.tempDir().resolvingSymlinksInPath()
        fs = LocalFileSystem(homeDirectory: home.path)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testMuseAccountsAreNeverDroppedDuplicatedOrDismissed() throws {
        try FileManager.default.createDirectory(atPath: home.path + "/.codex/sessions", withIntermediateDirectories: true)
        var config = AppConfig()
        let a = AccountReconciler.addWebAccount(providerID: "museai", name: "Muse Power", to: &config)
        let b = AccountReconciler.addWebAccount(providerID: "museai", name: "Muse Power 2", to: &config)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(a.origin, .signedIn)

        let discovery = AccountDiscovery(fileSystem: fs, environment: [:])
        AccountReconciler.merge(discovery.discover(), into: &config, fileSystem: fs)
        AccountReconciler.merge(discovery.discover(), into: &config, fileSystem: fs)
        XCTAssertEqual(config.accounts.filter { $0.providerID == "museai" }.map(\.id), [a.id, b.id])
        XCTAssertEqual(config.accounts.filter { $0.providerID == "codex" }.count, 1)

        // Removing one Muse account leaves the other and records no dismissed path.
        AccountReconciler.remove(a.id, from: &config, fileSystem: fs)
        XCTAssertEqual(config.dismissedAccounts.filter { $0.hasPrefix("museai") }, [])
        AccountReconciler.merge(discovery.discover(), into: &config, fileSystem: fs)
        XCTAssertEqual(config.accounts.filter { $0.providerID == "museai" }.map(\.id), [b.id])

        // The folder-based add never merges two empty paths either.
        let c = AccountReconciler.add(providerID: "museai", dataPath: "", origin: .signedIn, name: "Muse", to: &config, fileSystem: fs)
        XCTAssertNotEqual(c.id, b.id)
        XCTAssertEqual(config.accounts.filter { $0.providerID == "museai" }.count, 2)
    }

    func testSignedInPathIsStoredByteForByte() throws {
        // Strings that normalisation would change: a double slash, a trailing slash, decomposed Unicode.
        let decomposed = "Cafe\u{301}"
        for literal in [home.path + "/accounts/claude//a1", home.path + "/accounts/claude/b2/", home.path + "/accounts/\(decomposed)/c3"] {
            var config = AppConfig()
            let account = AccountReconciler.add(providerID: "claude", dataPath: literal, origin: .signedIn, name: nil, to: &config, fileSystem: fs)
            XCTAssertEqual(account.dataPath.utf8.count, literal.utf8.count)
            XCTAssertTrue(account.dataPath.utf8.elementsEqual(literal.utf8), literal)
            // Adding the tidied form again finds the same account instead of a second one.
            let again = AccountReconciler.add(providerID: "claude", dataPath: normalizedPath(literal, home: home.path),
                                              origin: .signedIn, name: nil, to: &config, fileSystem: fs)
            XCTAssertEqual(again.id, account.id)
            XCTAssertEqual(config.accounts.count, 1)
            XCTAssertTrue(config.accounts[0].dataPath.utf8.elementsEqual(literal.utf8))
        }
        // Manual folders are still tidied.
        var config = AppConfig()
        let manual = AccountReconciler.add(providerID: "codex", dataPath: "~/x/", origin: .manual, name: nil, to: &config, fileSystem: fs)
        XCTAssertEqual(manual.dataPath, home.path + "/x")
    }

    func testRelaunchRediscoversManagedHomesWithTheSameString() throws {
        // The managed root is reached through a symlink (like /var -> /private/var); the stored path keeps it.
        let real = home.appendingPathComponent("real").path
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home.path + "/link", withDestinationPath: real)
        let root = home.path + "/link/accounts"
        let claudeHome = root + "/claude/0f8e2c1a-1111-4222-8333-944445555666"
        let geminiHome = root + "/gemini/1a2b3c4d-1111-4222-8333-944445555666"
        try write(claudeHome + "/.claude.json", #"{"oauthAccount":{"emailAddress":"new@example.com","accountUuid":"u"}}"#)
        try write(geminiHome + "/.gemini/oauth_creds.json", #"{"refresh_token":"R"}"#)
        try write(geminiHome + "/.gemini/google_accounts.json", #"{"active":"g@example.com"}"#)

        // What the driver reported at sign-in time (Gemini: the data folder).
        var config = AppConfig()
        for (provider, path) in [("claude", claudeHome), ("gemini", geminiHome + "/.gemini")] {
            let data = AccountReconciler.dataPath(forManagedHome: path, providerID: provider, fileSystem: fs)
            XCTAssertEqual(data, path)
            AccountReconciler.add(providerID: provider, dataPath: data, origin: .signedIn, name: nil, to: &config, fileSystem: fs)
        }
        let before = config.accounts.map(\.dataPath)
        XCTAssertEqual(before, [claudeHome, geminiHome + "/.gemini"])

        // After a relaunch, discovery finds the same homes and produces the same strings.
        let discovery = AccountDiscovery(fileSystem: fs, environment: [:], managedRoot: root)
        let found = discovery.discover().filter { $0.origin == .signedIn }
        XCTAssertEqual(found.map(\.dataPath), [claudeHome, geminiHome + "/.gemini"])
        XCTAssertFalse(AccountReconciler.merge(discovery.discover(), into: &config, fileSystem: fs), "relaunch scan is a no-op")
        XCTAssertEqual(config.accounts.map(\.dataPath), before, "no second account, no rewritten path")

        // A config lost between launches is rebuilt with the literal strings too.
        var fresh = AppConfig()
        AccountReconciler.merge(discovery.discover(), into: &fresh, fileSystem: fs)
        XCTAssertEqual(fresh.accounts.map(\.dataPath), before)
        XCTAssertEqual(fresh.accounts.map(\.origin), [.signedIn, .signedIn])
    }

    func testManagedAccountPathForAliasesAndOrphanSweep() throws {
        let root = home.path + "/accounts"
        let driver = FakeLoginDriver(root: root)
        let gem = Account(providerID: "gemini", name: "g", dataPath: root + "/gemini/G/.gemini", origin: .signedIn)
        XCTAssertEqual(SignInSessions.managedAccountPath(for: gem, driver: driver), root + "/gemini/G/.gemini",
                       "the shell alias gets the registered form, not the home above it")
        let claude = Account(providerID: "claude", name: "c", dataPath: root + "/claude//C", origin: .signedIn)
        XCTAssertEqual(SignInSessions.managedAccountPath(for: claude, driver: driver), root + "/claude//C")
        XCTAssertNil(SignInSessions.managedAccountPath(for: Account(providerID: "claude", name: "d", dataPath: "/Users/me/.claude", origin: .signedIn), driver: driver))
        XCTAssertNil(SignInSessions.managedAccountPath(for: Account(providerID: "claude", name: "d", dataPath: root + "/claude/C", origin: .detected), driver: driver))
        XCTAssertNil(SignInSessions.managedAccountPath(for: Account(providerID: "museai", name: "m", dataPath: "", origin: .signedIn), driver: driver))

        for dir in ["gemini/G/.gemini", "claude/C", "claude/OLD", "claude/NEW", "codex/X"] {
            try FileManager.default.createDirectory(atPath: root + "/" + dir, withIntermediateDirectories: true)
        }
        let now = TestSupport.now
        let ages: [String: TimeInterval] = [root + "/claude/NEW": 60]
        let orphans = SignInSessions.orphanedManagedHomes(
            root: root, accounts: [gem, claude, Account(providerID: "museai", name: "m", dataPath: "")], fileSystem: fs,
            modificationDate: { now.addingTimeInterval(-(ages[$0] ?? 7200)) }, now: now)
        XCTAssertEqual(orphans, [root + "/claude/OLD", root + "/codex/X"], "used and recent homes are kept")
        XCTAssertEqual(SignInSessions.orphanedManagedHomes(root: root + "/missing", accounts: [], fileSystem: fs,
                                                           modificationDate: { _ in nil }, now: now), [])
    }
}
