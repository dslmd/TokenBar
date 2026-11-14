import Foundation
import XCTest
@testable import TokenBarCore

final class ShellProfileParserTests: XCTestCase {
    let vars: Set<String> = ["CLAUDE_CONFIG_DIR", "CODEX_HOME", "GEMINI_CLI_HOME"]

    func testParsesExportsAliasesFunctionsAndFish() {
        let text = #"""
        # export CODEX_HOME=~/commented-out
        export CLAUDE_CONFIG_DIR="$HOME/.claude-main"
        alias claude-work='CLAUDE_CONFIG_DIR=~/.claude-work claude'
        alias cx="CODEX_HOME=\"${HOME}/work/codex\" codex"
        codex-client() { CODEX_HOME=/opt/client/codex codex "$@"; }
        set -gx GEMINI_CLI_HOME ~/gem-work
        set -g CODEX_HOME /not/exported
        export CODEX_HOME=$SOMETHING_ELSE/codex
        alias xc='XCLAUDE_CONFIG_DIR=/nope claude'
        """#
        let hints = ShellProfileParser.parse(text, variables: vars, home: "/Users/me", file: "/Users/me/.zshrc")
        XCTAssertEqual(hints.map { "\($0.name)=\($0.value)|\($0.label ?? "-")" }, [
            "CLAUDE_CONFIG_DIR=/Users/me/.claude-main|-",
            "CLAUDE_CONFIG_DIR=/Users/me/.claude-work|claude-work",
            "CODEX_HOME=/Users/me/work/codex|cx",
            "CODEX_HOME=/opt/client/codex|codex-client",
            "GEMINI_CLI_HOME=/Users/me/gem-work|-",
        ])
    }

    func testTrailingSlashAndDotsAreNormalised() {
        let hints = ShellProfileParser.parse("export CODEX_HOME=~/a/../codex-x/", variables: vars, home: "/Users/me")
        XCTAssertEqual(hints.map(\.value), ["/Users/me/codex-x"])
    }
}

final class DiscoveryTests: XCTestCase {
    private var home: URL!
    private var fs: LocalFileSystem!

    override func setUpWithError() throws {
        home = try TestSupport.tempDir().resolvingSymlinksInPath()
        fs = LocalFileSystem(homeDirectory: home.path)
    }

    private func mkdir(_ rel: String) throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(rel), withIntermediateDirectories: true)
    }

    private func write(_ rel: String, _ text: String) throws {
        let url = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    static func jwt(_ claims: String) -> String {
        let b64 = Data(claims.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJub25lIn0.\(b64).sig"
    }

    private func buildHome() throws {
        // Claude: default profile, an rc-file profile with a signed-in identity, a symlink to it, a non-profile folder.
        try mkdir(".claude/projects")
        try write(".claude.json", #"{"oauthAccount":{"emailAddress":"me@example.com","accountUuid":"u1"}}"#)
        try mkdir(".claude-work/projects")
        try write(".claude-work/.claude.json", #"{"oauthAccount":{"emailAddress":"work@example.com","organizationName":"Acme"}}"#)
        try write(".claude-work/.credentials.json", #"{"claudeAiOauth":{"accessToken":"SECRET-AT","subscriptionType":"max"}}"#)
        try FileManager.default.createSymbolicLink(atPath: home.appendingPathComponent(".claude-link").path,
                                                   withDestinationPath: home.appendingPathComponent(".claude-work").path)
        try mkdir(".claude-swap-backup/sessions")
        // Codex: default home with an id_token, plus a profile only named by an alias.
        try mkdir(".codex/sessions")
        let claims = #"{"email":"dev@example.com","https://api.openai.com/auth":{"chatgpt_plan_type":"pro"}}"#
        try write(".codex/auth.json", #"{"tokens":{"id_token":"\#(Self.jwt(claims))","access_token":"SECRET","refresh_token":"R"}}"#)
        try mkdir("work/codex/archived_sessions")
        try write(".zshrc", """
        alias claude-work='CLAUDE_CONFIG_DIR=~/.claude-work/ claude'
        alias cx='CODEX_HOME=~/work/codex codex'
        export GEMINI_CLI_HOME=$HOME/gem
        export CODEX_HOME=~/missing-codex
        """)
        // Gemini: GEMINI_CLI_HOME relocates the home; data lives in <home>/.gemini.
        try write("gem/.gemini/google_accounts.json", #"{"active":"g@example.com","old":[]}"#)
        try mkdir(".gemini/tmp")
        // Managed sign-ins: one completed, one abandoned.
        try mkdir("managed/claude/A")
        try write("managed/claude/A/.claude.json", #"{"oauthAccount":{"emailAddress":"new@example.com","accountUuid":"u9"}}"#)
        try mkdir("managed/claude/B")
    }

    func testDiscoversAccountsWithoutConfiguration() throws {
        try buildHome()
        let found = AccountDiscovery(fileSystem: fs, environment: [:], managedRoot: home.path + "/managed").discover()
        let summary = found.map { "\($0.providerID) \($0.suggestedName) \($0.origin.rawValue) \($0.dataPath.replacingOccurrences(of: home.path, with: "~"))" }
        XCTAssertEqual(summary, [
            "claude work@example.com detected ~/.claude-work",
            "claude me@example.com detected ~/.claude",
            "claude new@example.com signedIn ~/managed/claude/A",
            "codex cx detected ~/work/codex",
            "codex dev@example.com detected ~/.codex",
            "gemini g@example.com detected ~/gem/.gemini",
            "gemini Default detected ~/.gemini",
        ])
        let work = try XCTUnwrap(found.first { $0.suggestedName == "work@example.com" })
        XCTAssertEqual(work.identity?.planLabel, "Max")
        XCTAssertEqual(work.identity?.organization, "Acme")
        XCTAssertEqual(work.foundVia, "CLAUDE_CONFIG_DIR in .zshrc")
        XCTAssertEqual(found.first { $0.providerID == "codex" && $0.dataPath.hasSuffix(".codex") }?.identity?.plan, "pro")
        // No token value may end up in anything discovery produces.
        XCTAssertFalse(String(describing: found).contains("SECRET"))
    }

    func testProcessEnvironmentAndManagedCheck() throws {
        try mkdir("elsewhere/projects")
        let found = AccountDiscovery(fileSystem: fs, environment: ["CLAUDE_CONFIG_DIR": home.path + "/elsewhere"],
                                     isManagedHome: { $0.hasSuffix("/elsewhere") }).discover()
        XCTAssertTrue(found.isEmpty, "a managed home without a sign-in is not an account")
        try write("elsewhere/.claude.json", #"{"oauthAccount":{"accountUuid":"x"}}"#)
        let again = AccountDiscovery(fileSystem: fs, environment: ["CLAUDE_CONFIG_DIR": home.path + "/elsewhere"],
                                     isManagedHome: { $0.hasSuffix("/elsewhere") }).discover()
        XCTAssertEqual(again.map(\.origin), [.signedIn])
        XCTAssertEqual(again.first?.suggestedName, "Signed-in account")
    }

    func testSameEmailInTwoProfilesIsDisambiguated() throws {
        try mkdir(".codex/sessions")
        try mkdir(".codex-copy/sessions")
        let auth = #"{"tokens":{"id_token":"\#(Self.jwt(#"{"email":"same@example.com"}"#))"}}"#
        try write(".codex/auth.json", auth)
        try write(".codex-copy/auth.json", auth)
        let names = AccountDiscovery(fileSystem: fs, environment: [:]).discover().map(\.suggestedName)
        XCTAssertEqual(names, ["same@example.com · Default", "same@example.com · codex-copy"])
    }

    func testReconcileAddsKeepsRemovalsAndNeverDuplicates() throws {
        try buildHome()
        let discovery = AccountDiscovery(fileSystem: fs, environment: [:], managedRoot: home.path + "/managed")
        var config = AppConfig()
        XCTAssertTrue(AccountReconciler.merge(discovery.discover(), into: &config, fileSystem: fs))
        XCTAssertEqual(config.accounts.count, 7)
        XCTAssertFalse(AccountReconciler.merge(discovery.discover(), into: &config, fileSystem: fs), "second scan is a no-op")

        // Remove one: it stays removed on the next scan.
        let codex = try XCTUnwrap(config.accounts.first { $0.name == "dev@example.com" })
        AccountReconciler.remove(codex.id, from: &config, fileSystem: fs)
        AccountReconciler.merge(discovery.discover(), into: &config, fileSystem: fs)
        XCTAssertFalse(config.accounts.contains { $0.name == "dev@example.com" })

        // Adding the same folder by hand (via a symlink and a trailing slash) re-enables it, once.
        AccountReconciler.add(providerID: "codex", dataPath: "~/.codex/", origin: .manual, name: nil, to: &config, fileSystem: fs)
        AccountReconciler.add(providerID: "claude", dataPath: home.path + "/.claude-link/", origin: .manual, name: nil, to: &config, fileSystem: fs)
        AccountReconciler.merge(discovery.discover(), into: &config, fileSystem: fs)
        XCTAssertEqual(config.accounts.filter { $0.providerID == "codex" }.count, 2)
        XCTAssertEqual(config.accounts.filter { $0.providerID == "claude" }.count, 3)
    }

    func testReconcileDropsSymlinkDuplicatesFromOldConfigsAndRenamesAutomatically() throws {
        try buildHome()
        var config = AppConfig(accounts: [
            Account(providerID: "claude", name: "Mine", dataPath: home.path + "/.claude-work"),
            Account(providerID: "claude", name: "dup", dataPath: home.path + "/.claude-link/"),
            Account(providerID: "codex", name: "x", dataPath: "~/.codex", autoNamed: true),
        ])
        AccountReconciler.merge(AccountDiscovery(fileSystem: fs, environment: [:]).discover(), into: &config, fileSystem: fs)
        XCTAssertEqual(config.accounts.filter { $0.providerID == "claude" }.map(\.name).sorted(), ["Mine", "me@example.com"])
        XCTAssertEqual(config.accounts.first { $0.name == "Mine" }?.origin, .detected, "legacy accounts learn their origin")
        XCTAssertEqual(config.accounts.first { $0.providerID == "codex" && $0.dataPath == "~/.codex" }?.name, "dev@example.com")
    }

    func testOldConfigStillLoads() throws {
        // A config.json written by version 0.2 (no origin/autoNamed/isEnabled/dismissedAccounts, old default name).
        let legacyDefault = "\u{9ED8}\u{8BA4}"
        let json = """
        {"version":1,"settings":{"refreshIntervalSeconds":60,"onlineQuotaEnabled":false},
         "accounts":[{"id":"11111111-2222-3333-4444-555555555555","providerID":"claude","name":"\(legacyDefault)","dataPath":"~/.claude"},
                     {"id":"not-a-uuid","providerID":"codex","name":"bad","dataPath":"x"},
                     {"id":"11111111-2222-3333-4444-555555555556","providerID":"codex","name":"Work","dataPath":"/w","onlineQuotaEnabled":false}]}
        """
        let dir = try TestSupport.tempDir()
        let store = ConfigStore(url: dir.appendingPathComponent("config.json"))
        try Data(json.utf8).write(to: store.url)
        let cfg = try XCTUnwrap(store.load())
        XCTAssertEqual(cfg.accounts.map(\.name), [legacyDefault, "Work"], "a malformed entry does not drop the others")
        XCTAssertEqual(cfg.accounts.map(\.autoNamed), [true, false])
        XCTAssertEqual(cfg.accounts.map(\.isEnabled), [true, true])
        XCTAssertNil(cfg.accounts[0].origin)
        XCTAssertFalse(cfg.accounts[1].onlineQuotaEnabled)
        XCTAssertFalse(cfg.settings.onlineQuotaEnabled)
        XCTAssertEqual(cfg.dismissedAccounts, [])
        try store.save(cfg)
        XCTAssertEqual(store.load(), cfg)
    }

    func testManagedGeminiHomeMapsToDataFolder() {
        XCTAssertEqual(AccountReconciler.dataPath(forManagedHome: "/m/gemini/X", providerID: "gemini", fileSystem: fs), "/m/gemini/X/.gemini")
        XCTAssertEqual(AccountReconciler.dataPath(forManagedHome: "/m/gemini/X/.gemini/", providerID: "gemini", fileSystem: fs), "/m/gemini/X/.gemini")
        XCTAssertEqual(AccountReconciler.dataPath(forManagedHome: "/m/codex/X/", providerID: "codex", fileSystem: fs), "/m/codex/X")
    }

    func testFolderNames() {
        let h = "/Users/me"
        XCTAssertEqual(AccountNaming.folderName("/Users/me/.claude", providerID: "claude", home: h), "Default")
        XCTAssertEqual(AccountNaming.folderName("/Users/me/.config/claude", providerID: "claude", home: h), "claude (.config)")
        XCTAssertEqual(AccountNaming.folderName("/Users/me/.claude-work", providerID: "claude", home: h), "claude-work")
        XCTAssertEqual(AccountNaming.folderName("/Users/me/.gemini", providerID: "gemini", home: h), "Default")
        XCTAssertEqual(AccountNaming.folderName("/x/work/.gemini", providerID: "gemini", home: h), "work")
    }

    func testClaudeKeychainSuffixMatchesReportedExample() {
        // Reported by third-party tools: CLAUDE_CONFIG_DIR=/tmp/claude-alt -> "Claude Code-credentials-04923786".
        XCTAssertEqual(String(SHA256Lite.hex("/tmp/claude-alt").prefix(8)), "04923786")
        let sources = ClaudeQuotaBackend().credentialSources(forDataPath: "/tmp/claude-alt", home: URL(fileURLWithPath: "/Users/me"))
        XCTAssertTrue(sources.contains(.keychain(service: "Claude Code-credentials-04923786")))
        XCTAssertFalse(sources.contains(.keychain(service: "Claude Code-credentials")))
    }

    func testAccountHealth() {
        let a = Account(providerID: "claude", name: "a", dataPath: "/x")
        var off = a
        off.isEnabled = false
        let now = TestSupport.now
        XCTAssertEqual(AccountHealth.evaluate(account: off, usage: nil, quota: nil).0, .disabled)
        XCTAssertEqual(AccountHealth.evaluate(account: a, usage: nil, quota: nil).0, .unknown)
        XCTAssertEqual(AccountHealth.evaluate(account: a, usage: AccountUsage(updatedAt: now, status: .dataDirectoryMissing), quota: nil).0, .error)
        XCTAssertEqual(AccountHealth.evaluate(account: a, usage: AccountUsage(updatedAt: now), quota: QuotaResult(issue: .notSignedIn)).0, .warning)
        XCTAssertEqual(AccountHealth.evaluate(account: a, usage: AccountUsage(updatedAt: now), quota: QuotaResult(issue: .disabled)).0, .ok)
    }
}

// MARK: - Sign-in glue with a fake driver

final class FakeLoginDriver: AccountLoginDriving, @unchecked Sendable {
    final class Handle: LoginHandle, @unchecked Sendable {
        var cancelled = false
        let onCancel: () -> Void
        init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }
        func cancel() { cancelled = true; onCancel() }
    }

    var root: String
    var callbacks: [String: (LoginPhase) -> Void] = [:]
    var handles: [Handle] = []
    var removed: [String] = []
    var syncResult: LoginPhase?

    init(root: String) { self.root = root }

    func unavailableReason(providerID: String) -> String? { providerID == "muse" ? "Not supported" : nil }
    func start(providerID: String, onPhase: @escaping @Sendable (LoginPhase) -> Void) -> LoginHandle {
        callbacks[providerID] = onPhase
        if let r = syncResult { onPhase(r) }
        let h = Handle { onPhase(.cancelled) }
        handles.append(h)
        return h
    }
    func shellAlias(providerID: String, homePath: String) -> String? { "alias \(providerID)-x='X=\(homePath) \(providerID)'" }
    func removeManagedHome(at homePath: String) { removed.append(homePath) }
    func isManagedHome(_ path: String) -> Bool { path.hasPrefix(root + "/") }
}

final class SignInSessionsTests: XCTestCase {
    @MainActor private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @MainActor func testSuccessRegistersSignedInAccount() async throws {
        let home = try TestSupport.tempDir().resolvingSymlinksInPath()
        let fs = LocalFileSystem(homeDirectory: home.path)
        let managed = home.path + "/accounts/claude/A"
        try FileManager.default.createDirectory(atPath: managed, withIntermediateDirectories: true)
        try Data(#"{"oauthAccount":{"emailAddress":"new@example.com"}}"#.utf8).write(to: URL(fileURLWithPath: managed + "/.claude.json"))

        let driver = FakeLoginDriver(root: home.path + "/accounts")
        let sessions = SignInSessions(driver: driver)
        var config = AppConfig()
        sessions.onSuccess = { provider, path in
            let data = AccountReconciler.dataPath(forManagedHome: path, providerID: provider, fileSystem: fs)
            AccountReconciler.add(providerID: provider, dataPath: data, origin: .signedIn, name: nil, to: &config, fileSystem: fs)
        }
        sessions.start("claude")
        XCTAssertEqual(sessions.phases["claude"], .locatingCLI)
        XCTAssertTrue(sessions.isRunning("claude"))
        driver.callbacks["claude"]?(.waitingForUser(hint: "Finish signing in in your browser"))
        await settle()
        XCTAssertEqual(sessions.phases["claude"], .waitingForUser(hint: "Finish signing in in your browser"))
        driver.callbacks["claude"]?(.succeeded(homePath: managed))
        await settle()
        XCTAssertFalse(sessions.isRunning("claude"))
        XCTAssertEqual(config.accounts.map(\.name), ["new@example.com"])
        XCTAssertEqual(config.accounts.first?.origin, .signedIn)

        // Removing it deletes the managed home through the driver.
        let account = try XCTUnwrap(config.accounts.first)
        XCTAssertEqual(SignInSessions.managedHomeToRemove(for: account, driver: driver, home: home.path), managed)
    }

    @MainActor func testCancelIgnoresLateCallbacks() async {
        let driver = FakeLoginDriver(root: "/m")
        let sessions = SignInSessions(driver: driver)
        var successes = 0
        sessions.onSuccess = { _, _ in successes += 1 }
        sessions.start("codex")
        let late = driver.callbacks["codex"]
        sessions.cancel("codex")
        XCTAssertTrue(driver.handles.last?.cancelled == true)
        XCTAssertEqual(sessions.phases["codex"], .cancelled)
        late?(.succeeded(homePath: "/m/codex/A"))
        await settle()
        XCTAssertEqual(successes, 0)
        XCTAssertEqual(sessions.phases["codex"], .cancelled)
        sessions.dismiss("codex")
        XCTAssertNil(sessions.phases["codex"])
    }

    @MainActor func testImmediateFailureIsReported() async {
        let driver = FakeLoginDriver(root: "/m")
        driver.syncResult = .failed(message: "Codex is not installed. Install it with: npm install -g @openai/codex")
        let sessions = SignInSessions(driver: driver)
        sessions.start("codex")
        await settle()
        XCTAssertEqual(sessions.phases["codex"], .failed(message: "Codex is not installed. Install it with: npm install -g @openai/codex"))
        XCTAssertFalse(sessions.isRunning("codex"))
        XCTAssertEqual(sessions.unavailableReason(providerID: "muse"), "Not supported")
    }

    func testRemovalNeverTouchesDetectedOrUnmanagedFolders() {
        let driver = FakeLoginDriver(root: "/m")
        let detected = Account(providerID: "claude", name: "a", dataPath: "/m/claude/A", origin: .detected)
        XCTAssertNil(SignInSessions.managedHomeToRemove(for: detected, driver: driver, home: "/Users/me"))
        let outside = Account(providerID: "claude", name: "a", dataPath: "/Users/me/.claude", origin: .signedIn)
        XCTAssertNil(SignInSessions.managedHomeToRemove(for: outside, driver: driver, home: "/Users/me"))
        let gem = Account(providerID: "gemini", name: "g", dataPath: "/m/gemini/G/.gemini", origin: .signedIn)
        XCTAssertEqual(SignInSessions.managedHomeToRemove(for: gem, driver: driver, home: "/Users/me"), "/m/gemini/G")
    }
}
