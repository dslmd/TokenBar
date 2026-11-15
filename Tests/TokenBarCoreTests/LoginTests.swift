import Foundation
import XCTest
@testable import TokenBarCore

// MARK: - Fakes

/// In-memory file system for locator tests: only `executables` exist as runnable files.
private struct FakeLocatorFS: LoginFileSystem {
    var executables: Set<String> = []
    var directories: [String: [String]] = [:]
    var files: [String: Data] = [:]

    func fileExists(_ path: String) -> Bool { executables.contains(path) || files[path] != nil || directories[path] != nil }
    func isDirectory(_ path: String) -> Bool { directories[path] != nil }
    func isExecutableFile(_ path: String) -> Bool { executables.contains(path) }
    func contentsOfDirectory(_ path: String) -> [String] { directories[path] ?? [] }
    func createPrivateDirectory(_ path: String) throws { throw CocoaError(.fileWriteNoPermission) }
    func writeFile(_ path: String, contents: Data, mode: Int) throws { throw CocoaError(.fileWriteNoPermission) }
    func readFile(_ path: String) -> Data? { files[path] }
    func removeItem(_ path: String) throws {}
    func realPath(_ path: String) -> String? { fileExists(path) ? path : nil }
}

/// The real file system, except that only executables under `allowedPrefix` are visible,
/// so CLIs installed on the test machine never leak into the tests.
private struct SandboxedFS: LoginFileSystem {
    let real = SystemLoginFileSystem()
    let allowedPrefix: String

    func fileExists(_ path: String) -> Bool { real.fileExists(path) }
    func isDirectory(_ path: String) -> Bool { real.isDirectory(path) }
    func isExecutableFile(_ path: String) -> Bool { path.hasPrefix(allowedPrefix) && real.isExecutableFile(path) }
    func contentsOfDirectory(_ path: String) -> [String] { real.contentsOfDirectory(path) }
    func createPrivateDirectory(_ path: String) throws { try real.createPrivateDirectory(path) }
    func writeFile(_ path: String, contents: Data, mode: Int) throws { try real.writeFile(path, contents: contents, mode: mode) }
    func readFile(_ path: String) -> Data? { real.readFile(path) }
    func removeItem(_ path: String) throws { try real.removeItem(path) }
    func realPath(_ path: String) -> String? { real.realPath(path) }
}

private final class FakeChild: LoginChildProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var onExit: (@Sendable (Int32) -> Void)?
    private var _terminated = false
    let spec: LoginLaunchSpec

    init(spec: LoginLaunchSpec, onExit: @escaping @Sendable (Int32) -> Void) {
        self.spec = spec
        self.onExit = onExit
    }

    var terminated: Bool { lock.lock(); defer { lock.unlock() }; return _terminated }

    func terminate() {
        lock.lock(); _terminated = true; lock.unlock()
    }

    /// Simulates the child exiting; only the first call reports.
    func exit(_ status: Int32) {
        lock.lock()
        let handler = onExit
        onExit = nil
        lock.unlock()
        handler?(status)
    }
}

private final class FakeLauncher: LoginProcessLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var _children: [FakeChild] = []
    private var _runs: [LoginLaunchSpec] = []
    private var _terminatedPIDs: [Int32] = []
    var runHandler: @Sendable (LoginLaunchSpec) -> LoginRunResult? = { _ in nil }
    var launchHook: (@Sendable (FakeChild) -> Void)?
    var launchError: Error?
    var runningPIDs: Set<Int32> = []

    var children: [FakeChild] { lock.lock(); defer { lock.unlock() }; return _children }
    var runs: [LoginLaunchSpec] { lock.lock(); defer { lock.unlock() }; return _runs }
    var terminatedPIDs: [Int32] { lock.lock(); defer { lock.unlock() }; return _terminatedPIDs }

    func launch(_ spec: LoginLaunchSpec, onExit: @escaping @Sendable (Int32) -> Void) throws -> LoginChildProcess {
        if let launchError { throw launchError }
        let child = FakeChild(spec: spec, onExit: onExit)
        lock.lock(); _children.append(child); lock.unlock()
        launchHook?(child)
        return child
    }

    func run(_ spec: LoginLaunchSpec, timeout: TimeInterval) -> LoginRunResult? {
        lock.lock(); _runs.append(spec); lock.unlock()
        return runHandler(spec)
    }

    func terminateProcess(pid: Int32) {
        lock.lock(); _terminatedPIDs.append(pid); lock.unlock()
    }

    func isProcessRunning(pid: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return runningPIDs.contains(pid)
    }
}

/// A clock whose sleepers only wake when the test advances time.
private final class ManualClock: LoginClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)
    private var waiters: [(deadline: Date, continuation: CheckedContinuation<Void, Never>)] = []

    func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }

    var sleeperCount: Int { lock.lock(); defer { lock.unlock() }; return waiters.count }

    func sleep(seconds: TimeInterval) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            waiters.append((current.addingTimeInterval(seconds), c))
            lock.unlock()
        }
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        let now = current
        let ready = waiters.filter { $0.deadline <= now }
        waiters.removeAll { $0.deadline <= now }
        lock.unlock()
        ready.forEach { $0.continuation.resume() }
    }
}

private final class PhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _phases: [LoginPhase] = []

    var phases: [LoginPhase] { lock.lock(); defer { lock.unlock() }; return _phases }

    func record(_ p: LoginPhase) { lock.lock(); _phases.append(p); lock.unlock() }

    var terminalPhases: [LoginPhase] {
        phases.filter {
            switch $0 {
            case .succeeded, .failed, .cancelled: return true
            default: return false
            }
        }
    }

    var isWaiting: Bool { phases.contains { if case .waitingForUser = $0 { return true }; return false } }
}

private func waitUntil(_ timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                       _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("Timed out waiting for condition", file: file, line: line)
            return
        }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
}

/// Builds a driver over a temp HOME and a managed root whose path contains a space.
private struct Harness {
    let base: URL
    let home: String
    let root: URL
    let clock = ManualClock()
    let launcher = FakeLauncher()
    let recorder = PhaseRecorder()
    let driver: CLILoginDriver

    init(installed: [String] = ["codex", "claude", "gemini"], options: CLILoginDriver.Options? = nil,
         probe: CLILoginDriver.KeychainProbe? = nil) throws {
        base = try TestSupport.tempDir()
        home = base.appendingPathComponent("home").path
        root = base.appendingPathComponent("Library/Application Support/TokenBar/accounts")
        let bin = (home as NSString).appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        for name in installed {
            let p = (bin as NSString).appendingPathComponent(name)
            try "#!/bin/sh\nexit 0\n".write(toFile: p, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p)
        }
        var opts = options ?? CLILoginDriver.Options()
        opts.loginShellPath = "/nonexistent/zsh"
        opts.scriptDirectory = base.appendingPathComponent("tmp dir")
        driver = CLILoginDriver(managedRoot: root, fileSystem: SandboxedFS(allowedPrefix: base.path),
                                launcher: launcher, clock: clock,
                                environment: LoginEnvironment(variables: ["PATH": "/usr/bin:/bin",
                                                                          "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/x"],
                                                              homeDirectory: home),
                                options: opts, claudeKeychainProbe: probe)
    }

    func start(_ provider: String) -> LoginHandle {
        let recorder = self.recorder
        return driver.start(providerID: provider) { recorder.record($0) }
    }

    func providerHomes(_ provider: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(provider).path)) ?? []
    }

    /// Waits until the poll loop is asleep (so state changes land on the next tick).
    func waitForSleep() async { await waitUntil { clock.sleeperCount > 0 } }

    func tick(_ seconds: TimeInterval = 1) async {
        await waitForSleep()
        clock.advance(by: seconds)
    }
}

private func mode(_ path: String) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

// MARK: - Tests

final class LoginTests: XCTestCase {

    // MARK: Locating binaries

    func testLocatorOrder() {
        let home = "/Users/me"
        var fs = FakeLocatorFS()
        fs.directories["\(home)/.nvm/versions/node"] = ["v18.20.0", "v20.11.1", "v9.0.0"]
        fs.files["\(home)/.npmrc"] = Data("registry=x\nprefix = ~/custom-npm\n".utf8)
        let ordered = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/opt/npm-env/bin/codex",
            "\(home)/custom-npm/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.bun/bin/codex",
            "\(home)/.volta/bin/codex",
            "\(home)/.nvm/versions/node/v20.11.1/bin/codex",
            "\(home)/.nvm/versions/node/v18.20.0/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.claude/local/codex",
            "/env/path/codex",
        ]
        fs.executables = Set(ordered)
        let env = LoginEnvironment(variables: ["PATH": "/env/path:relative", "NPM_CONFIG_PREFIX": "/opt/npm-env"],
                                   homeDirectory: home)
        for expected in ordered {
            let locator = CLILocator(fileSystem: fs, launcher: FakeLauncher(), environment: env,
                                     loginShellPath: "/bin/zsh", loginShellTimeout: 1)
            XCTAssertEqual(locator.locate("codex", extraDirectories: ["\(home)/.claude/local"]), expected)
            fs.executables.remove(expected)
        }
        let locator = CLILocator(fileSystem: fs, launcher: FakeLauncher(), environment: env,
                                 loginShellPath: "/bin/zsh", loginShellTimeout: 1)
        XCTAssertNil(locator.locate("codex"))
        XCTAssertFalse(locator.candidateDirectories().contains("relative"))
    }

    func testLoginShellFallback() {
        var fs = FakeLocatorFS()
        fs.executables = ["/bin/zsh", "/Users/me/.fnm/node/bin/gemini", "/Users/me/old/gemini"]
        let launcher = FakeLauncher()
        launcher.runHandler = { _ in
            LoginRunResult(status: 0, output: """
            Last login: today
            /Users/me/old/gemini
            alias gemini='npx gemini'
            /Users/me/.fnm/node/bin/gemini
            /not/executable/gemini
            Have a nice day

            """)
        }
        let locator = CLILocator(fileSystem: fs, launcher: launcher,
                                 environment: LoginEnvironment(variables: [:], homeDirectory: "/Users/me"),
                                 loginShellPath: "/bin/zsh", loginShellTimeout: 3)
        XCTAssertEqual(locator.locate("gemini"), "/Users/me/.fnm/node/bin/gemini")
        XCTAssertEqual(launcher.runs.first?.executable, "/bin/zsh")
        XCTAssertEqual(launcher.runs.first?.arguments, ["-lic", "command -v gemini"])

        // Non-zero status, missing shell and unsafe names never yield a path.
        launcher.runHandler = { _ in LoginRunResult(status: 1, output: "/Users/me/.fnm/node/bin/gemini\n") }
        XCTAssertNil(locator.locate("gemini"))
        XCTAssertNil(locator.locateWithLoginShell("gemini; rm -rf ~"))
        XCTAssertEqual(CLILocator.parseLoginShellOutput("gemini: aliased to x\n", isExecutable: { _ in true }), nil)
        XCTAssertEqual(CLILocator.parseLoginShellOutput("  /a/b  \n/c d\n", isExecutable: { $0 == "/a/b" }), "/a/b")
    }

    func testNotInstalled() async throws {
        let h = try Harness(installed: [])
        _ = h.start("codex")
        await waitUntil { !h.recorder.terminalPhases.isEmpty }
        XCTAssertEqual(h.recorder.phases, [.locatingCLI,
                                           .failed(message: "Codex CLI is not installed. Install it with: npm install -g @openai/codex")])
        XCTAssertTrue(h.launcher.children.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.root.path))
    }

    // MARK: Child-process flow

    func testCodexSuccessWhenCredentialsAppear() async throws {
        let h = try Harness()
        _ = h.start("codex")
        await waitUntil { h.recorder.isWaiting }
        let child = try XCTUnwrap(h.launcher.children.first)
        XCTAssertEqual(child.spec.arguments, ["login"])
        XCTAssertEqual(child.spec.executable, h.home + "/.local/bin/codex")
        let codexHome = try XCTUnwrap(child.spec.environment["CODEX_HOME"])
        XCTAssertTrue(codexHome.hasPrefix(h.root.path + "/codex/"))
        XCTAssertEqual(child.spec.currentDirectory, codexHome)
        XCTAssertTrue(child.spec.environment["PATH"]!.hasPrefix(h.home + "/.local/bin:"))
        XCTAssertTrue(child.spec.environment["PATH"]!.contains("/usr/bin"))
        for dir in [h.root.path, h.root.path + "/codex", codexHome] { XCTAssertEqual(mode(dir), 0o700, dir) }

        // Nothing yet: keeps waiting.
        await h.tick()
        await h.waitForSleep()
        XCTAssertTrue(h.recorder.terminalPhases.isEmpty)

        try #"{"tokens":{"access_token":"a"}}"#.write(toFile: codexHome + "/auth.json", atomically: true, encoding: .utf8)
        await h.tick()
        // Credentials seen while the CLI still runs: it gets a grace period to exit by itself.
        await h.waitForSleep()
        XCTAssertTrue(h.recorder.terminalPhases.isEmpty)
        await h.tick(5)
        await waitUntil { !h.recorder.terminalPhases.isEmpty }
        XCTAssertEqual(h.recorder.phases, [.locatingCLI,
                                           .waitingForUser(hint: "Continue in your browser to sign in to Codex."),
                                           .succeeded(homePath: codexHome)])
        XCTAssertTrue(child.terminated)
        XCTAssertTrue(FileManager.default.fileExists(atPath: codexHome + "/auth.json"))
        XCTAssertTrue(h.driver.isManagedHome(codexHome))
    }

    func testCodexSucceedsImmediatelyWhenChildExitsAfterWriting() async throws {
        let h = try Harness()
        _ = h.start("codex")
        await waitUntil { h.recorder.isWaiting }
        let child = try XCTUnwrap(h.launcher.children.first)
        let codexHome = child.spec.environment["CODEX_HOME"]!
        try #"{"OPENAI_API_KEY":null,"tokens":{"id_token":"x"}}"#.write(toFile: codexHome + "/auth.json", atomically: true, encoding: .utf8)
        child.exit(0)
        await h.tick()
        await waitUntil { !h.recorder.terminalPhases.isEmpty }
        XCTAssertEqual(h.recorder.terminalPhases, [.succeeded(homePath: codexHome)])
    }

    func testCodexExitZeroWithoutCredentialsFails() async throws {
        let h = try Harness()
        _ = h.start("codex")
        await waitUntil { h.recorder.isWaiting }
        let child = try XCTUnwrap(h.launcher.children.first)
        child.exit(0)
        await h.tick()
        await waitUntil { !h.recorder.terminalPhases.isEmpty }
        XCTAssertEqual(h.recorder.terminalPhases,
                       [.failed(message: "Codex CLI finished, but no credentials were saved for the new account.")])
        XCTAssertTrue(h.providerHomes("codex").isEmpty)
    }

    func testClaudeTrustsExitZeroAndScrubsEnvironment() async throws {
        let h = try Harness()
        _ = h.start("claude")
        await waitUntil { h.recorder.isWaiting }
        let child = try XCTUnwrap(h.launcher.children.first)
        XCTAssertEqual(child.spec.arguments, ["auth", "login", "--claudeai"])
        XCTAssertNil(child.spec.environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"])
        let dir = try XCTUnwrap(child.spec.environment["CLAUDE_CONFIG_DIR"])
        XCTAssertTrue(dir.hasPrefix(h.root.path + "/claude/"))
        // On macOS the tokens go to the Keychain, so nothing appears in the folder.
        child.exit(0)
        await h.tick()
        await waitUntil { !h.recorder.terminalPhases.isEmpty }
        XCTAssertEqual(h.recorder.terminalPhases, [.succeeded(homePath: dir)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir))
    }

    func testClaudeFileAndKeychainSignals() async throws {
        // .claude.json with an oauthAccount does not finish the sign-in while claude is still running (it is
        // written before the tokens are saved); claude exiting normally does.
        do {
            let h = try Harness()
            _ = h.start("claude")
            await waitUntil { h.recorder.isWaiting }
            let child = try XCTUnwrap(h.launcher.children.first)
            let dir = child.spec.environment["CLAUDE_CONFIG_DIR"]!
            try #"{"numStartups":1}"#.write(toFile: dir + "/.claude.json", atomically: true, encoding: .utf8)
            await h.tick()
            await h.waitForSleep()
            XCTAssertTrue(h.recorder.terminalPhases.isEmpty)
            try #"{"oauthAccount":{"accountUuid":"u","emailAddress":"e@x"}}"#.write(toFile: dir + "/.claude.json", atomically: true, encoding: .utf8)
            await h.tick()
            await h.tick(10)
            await h.waitForSleep()
            XCTAssertTrue(h.recorder.terminalPhases.isEmpty, "account info alone must not stop claude before it saves the tokens")
            XCTAssertFalse(child.terminated)
            child.exit(0)
            await h.tick()
            await waitUntil { !h.recorder.terminalPhases.isEmpty }
            XCTAssertEqual(h.recorder.terminalPhases, [.succeeded(homePath: dir)])
        }
        // The Keychain probe is asked for the per-directory service name.
        do {
            let asked = LockedBox<[String]>([])
            let h = try Harness(probe: { service in
                asked.update { $0.append(service) }
                return true
            })
            _ = h.start("claude")
            await waitUntil { h.recorder.isWaiting }
            let child = try XCTUnwrap(h.launcher.children.first)
            let dir = child.spec.environment["CLAUDE_CONFIG_DIR"]!
            await h.tick()
            await h.tick(5)
            await waitUntil { !h.recorder.terminalPhases.isEmpty }
            XCTAssertEqual(h.recorder.terminalPhases, [.succeeded(homePath: dir)])
            XCTAssertEqual(asked.get().first, CLILoginDriver.claudeKeychainService(forConfigDirectory: dir))
        }
    }

    func testClaudeKeychainServiceName() {
        // Independently computed: sha256("/Users/me/Library/Application Support/TokenBar/accounts/claude/abc")[:8]
        XCTAssertEqual(CLILoginDriver.claudeKeychainService(
            forConfigDirectory: "/Users/me/Library/Application Support/TokenBar/accounts/claude/abc"),
            "Claude Code-credentials-629bae74")
        // Matches the scheme ClaudeQuota already uses for extra profiles.
        let sources = ClaudeQuotaBackend().credentialSources(forDataPath: "/tmp/cfg", home: URL(fileURLWithPath: "/nohome"))
        let expected = CLILoginDriver.claudeKeychainService(forConfigDirectory: "/tmp/cfg")
        XCTAssertTrue(sources.contains { if case .keychain(let s) = $0 { return s == expected }; return false })
    }

    func testChildExitsNonZero() async throws {
        let h = try Harness()
        _ = h.start("codex")
        await waitUntil { h.recorder.isWaiting }
        let child = try XCTUnwrap(h.launcher.children.first)
        let codexHome = child.spec.environment["CODEX_HOME"]!
        try "partial".write(toFile: codexHome + "/log.txt", atomically: true, encoding: .utf8)
        child.exit(1)
        await h.tick()
        await waitUntil { !h.recorder.terminalPhases.isEmpty }
        XCTAssertEqual(h.recorder.terminalPhases, [.failed(message: "Codex CLI sign-in did not finish (exit code 1).")])
        XCTAssertFalse(FileManager.default.fileExists(atPath: codexHome))
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.root.path + "/codex"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.home + "/.local/bin/codex"))
    }

    func testLaunchFailure() async throws {
        let h = try Harness()
        h.launcher.launchError = CocoaError(.executableNotLoadable)
        _ = h.start("codex")
        await waitUntil { !h.recorder.terminalPhases.isEmpty }
        XCTAssertEqual(h.recorder.terminalPhases, [.failed(message: "Could not start Codex CLI.")])
        XCTAssertTrue(h.providerHomes("codex").isEmpty)
    }

    func testTimeout() async throws {
        var options = CLILoginDriver.Options()
        options.timeout = 600
        let h = try Harness(options: options)
        _ = h.start("codex")
        await waitUntil { h.recorder.isWaiting }
        let child = try XCTUnwrap(h.launcher.children.first)
        await h.tick(599)
        await h.waitForSleep()
        XCTAssertTrue(h.recorder.terminalPhases.isEmpty)
        await h.tick(1)
        await waitUntil { !h.recorder.terminalPhases.isEmpty }
        XCTAssertEqual(h.recorder.terminalPhases, [.failed(message: "Sign-in timed out. Try again.")])
        XCTAssertTrue(child.terminated)
        XCTAssertTrue(h.providerHomes("codex").isEmpty)
    }

    // MARK: Cancel

    func testCancelWhileLocating() async throws {
        let h = try Harness(installed: [])
        // Make the login-shell lookup reachable and block it until the test lets go.
        let shell = h.base.appendingPathComponent("zsh").path
        try "#!/bin/sh\n".write(toFile: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell)
        var options = CLILoginDriver.Options()
        options.loginShellPath = shell
        let gate = DispatchSemaphore(value: 0)
        let entered = LockedBox(false)
        let found = h.home + "/.local/bin/codex\n"
        h.launcher.runHandler = { _ in
            entered.set(true)
            gate.wait()
            return LoginRunResult(status: 0, output: found)
        }
        // Re-create the driver with the reachable shell (Harness pins a missing one).
        let driver = CLILoginDriver(managedRoot: h.root, fileSystem: SandboxedFS(allowedPrefix: h.base.path),
                                    launcher: h.launcher, clock: h.clock,
                                    environment: LoginEnvironment(variables: [:], homeDirectory: h.home), options: options)
        let recorder = h.recorder
        let handle = driver.start(providerID: "codex") { recorder.record($0) }
        await waitUntil { entered.get() }
        handle.cancel()
        handle.cancel()
        // The binary "appears" after cancel; nothing may be created or launched.
        try FileManager.default.createDirectory(atPath: h.home + "/.local/bin", withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(toFile: h.home + "/.local/bin/codex", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.home + "/.local/bin/codex")
        gate.signal()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(recorder.phases, [.locatingCLI, .cancelled])
        XCTAssertTrue(h.launcher.children.isEmpty)
        XCTAssertTrue(h.providerHomes("codex").isEmpty)
    }

    func testCancelDuringLaunch() async throws {
        let h = try Harness()
        let handleBox = LockedBox<LoginHandle?>(nil)
        h.launcher.launchHook = { _ in
            // Cancel lands between the process starting and the driver adopting it.
            while handleBox.get() == nil { usleep(1000) }
            handleBox.get()?.cancel()
        }
        handleBox.set(h.start("codex"))
        await waitUntil { !h.recorder.terminalPhases.isEmpty }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(h.recorder.phases, [.locatingCLI, .cancelled])
        XCTAssertTrue(try XCTUnwrap(h.launcher.children.first).terminated)
        XCTAssertTrue(h.providerHomes("codex").isEmpty)
    }

    func testCancelWhileWaiting() async throws {
        let h = try Harness()
        let handle = h.start("codex")
        await waitUntil { h.recorder.isWaiting }
        let child = try XCTUnwrap(h.launcher.children.first)
        handle.cancel()
        await waitUntil { !h.recorder.terminalPhases.isEmpty }
        XCTAssertEqual(h.recorder.terminalPhases, [.cancelled])
        XCTAssertTrue(child.terminated)
        XCTAssertTrue(h.providerHomes("codex").isEmpty)
        // A late exit or tick changes nothing.
        child.exit(0)
        h.clock.advance(by: 10)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(h.recorder.terminalPhases, [.cancelled])
    }

    func testCancelAfterSuccessIsNoOp() async throws {
        let h = try Harness()
        let handle = h.start("claude")
        await waitUntil { h.recorder.isWaiting }
        let child = try XCTUnwrap(h.launcher.children.first)
        let dir = child.spec.environment["CLAUDE_CONFIG_DIR"]!
        child.exit(0)
        await h.tick()
        await waitUntil { !h.recorder.terminalPhases.isEmpty }
        handle.cancel()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(h.recorder.terminalPhases, [.succeeded(homePath: dir)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir))
    }

    func testExactlyOneTerminalPhaseUnderRaces() async throws {
        for i in 0..<30 {
            let h = try Harness()
            let handle = h.start(i % 2 == 0 ? "codex" : "claude")
            await waitUntil { h.recorder.isWaiting }
            let child = try XCTUnwrap(h.launcher.children.first)
            let home = child.spec.environment["CODEX_HOME"] ?? child.spec.environment["CLAUDE_CONFIG_DIR"]!
            await h.waitForSleep()
            let clock = h.clock
            DispatchQueue.concurrentPerform(iterations: 4) { k in
                switch (k + i) % 4 {
                case 0: handle.cancel()
                case 1: child.exit(i % 3 == 0 ? 0 : 2)
                case 2: try? #"{"tokens":{"a":1}}"#.write(toFile: home + "/auth.json", atomically: true, encoding: .utf8)
                default: clock.advance(by: 700)
                }
            }
            await waitUntil { !h.recorder.terminalPhases.isEmpty }
            handle.cancel()
            h.clock.advance(by: 700)
            try await Task.sleep(nanoseconds: 20_000_000)
            let phases = h.recorder.phases
            XCTAssertEqual(h.recorder.terminalPhases.count, 1, "\(phases)")
            XCTAssertEqual(phases.first, .locatingCLI)
            XCTAssertTrue(phases.count == 3 && phases[1] != .locatingCLI && h.recorder.terminalPhases.first == phases[2], "\(phases)")
            if case .succeeded = phases.last! {
                XCTAssertTrue(FileManager.default.fileExists(atPath: home))
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: home))
            }
        }
    }

    // MARK: Terminal flow (Gemini)

    func testGeminiTerminalFlow() async throws {
        let h = try Harness()
        let opened = LockedBox<[String]>([])
        h.launcher.runHandler = { spec in
            opened.update { $0.append(contentsOf: spec.arguments) }
            return LoginRunResult(status: spec.executable == "/usr/bin/open" ? 0 : 1, output: "")
        }
        _ = h.start("gemini")
        await waitUntil { h.recorder.isWaiting }
        XCTAssertTrue(h.launcher.children.isEmpty)
        let scriptPath = try XCTUnwrap(opened.get().first)
        XCTAssertTrue(scriptPath.hasSuffix("/Sign in to Gemini CLI.command"))
        XCTAssertEqual(mode(scriptPath), 0o700)
        XCTAssertEqual(mode((scriptPath as NSString).deletingLastPathComponent), 0o700)
        let script = try String(contentsOfFile: scriptPath, encoding: .utf8)
        let home = try XCTUnwrap(h.providerHomes("gemini").first.map { h.root.path + "/gemini/" + $0 })
        XCTAssertTrue(script.contains("GEMINI_CLI_HOME='\(home)'"))
        XCTAssertTrue(script.contains("unset GEMINI_FORCE_ENCRYPTED_FILE_STORAGE"))
        let settings = try String(contentsOfFile: home + "/.gemini/settings.json", encoding: .utf8)
        XCTAssertTrue(settings.contains(#""selectedType":"oauth-personal""#))
        XCTAssertEqual(h.recorder.phases[1], .waitingForUser(hint: "Continue in the Terminal window that opened, then in your browser."))

        try #"{"refresh_token":"r","access_token":"a"}"#.write(toFile: home + "/.gemini/oauth_creds.json", atomically: true, encoding: .utf8)
        await h.tick()
        await waitUntil { !h.recorder.terminalPhases.isEmpty }
        XCTAssertEqual(h.recorder.terminalPhases, [.succeeded(homePath: home + "/.gemini")])
        XCTAssertFalse(FileManager.default.fileExists(atPath: (scriptPath as NSString).deletingLastPathComponent))
        XCTAssertTrue(h.launcher.terminatedPIDs.isEmpty)
        XCTAssertEqual(h.driver.shellAlias(providerID: "gemini", homePath: home + "/.gemini"),
                       "alias gemini-\(CLILoginDriver.aliasSuffix(for: home))='GEMINI_CLI_HOME=\"\(home)\" gemini'")
        // Removing the registered `.gemini` path removes the whole account folder.
        h.driver.removeManagedHome(at: home + "/.gemini")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home))
    }

    func testGeminiCancelStopsTerminalProcess() async throws {
        let h = try Harness()
        let opened = LockedBox<[String]>([])
        h.launcher.runHandler = { spec in
            opened.update { $0.append(contentsOf: spec.arguments) }
            return LoginRunResult(status: 0, output: "")
        }
        h.launcher.runningPIDs = [4242]
        let handle = h.start("gemini")
        await waitUntil { h.recorder.isWaiting }
        let scriptDir = (opened.get()[0] as NSString).deletingLastPathComponent
        try "4242\n".write(toFile: scriptDir + "/pid", atomically: true, encoding: .utf8)
        await h.tick()
        await h.waitForSleep()
        handle.cancel()
        await waitUntil { !h.recorder.terminalPhases.isEmpty }
        XCTAssertEqual(h.recorder.terminalPhases, [.cancelled])
        XCTAssertEqual(h.launcher.terminatedPIDs, [4242])
        XCTAssertFalse(FileManager.default.fileExists(atPath: scriptDir))
        XCTAssertTrue(h.providerHomes("gemini").isEmpty)
    }

    func testGeminiClosedBeforeSignIn() async throws {
        let h = try Harness()
        let opened = LockedBox<[String]>([])
        h.launcher.runHandler = { spec in
            opened.update { $0.append(contentsOf: spec.arguments) }
            return LoginRunResult(status: 0, output: "")
        }
        _ = h.start("gemini")
        await waitUntil { h.recorder.isWaiting }
        let scriptDir = (opened.get()[0] as NSString).deletingLastPathComponent
        try "999999\n".write(toFile: scriptDir + "/pid", atomically: true, encoding: .utf8)
        await h.tick()
        await waitUntil { !h.recorder.terminalPhases.isEmpty }
        XCTAssertEqual(h.recorder.terminalPhases, [.failed(message: "Gemini CLI closed before sign-in finished.")])
        XCTAssertTrue(h.providerHomes("gemini").isEmpty)
    }

    func testTerminalOpenFailure() async throws {
        let h = try Harness()
        h.launcher.runHandler = { _ in LoginRunResult(status: 1, output: "") }
        _ = h.start("gemini")
        await waitUntil { !h.recorder.terminalPhases.isEmpty }
        XCTAssertEqual(h.recorder.terminalPhases, [.failed(message: "Could not open Terminal.")])
        XCTAssertTrue(h.providerHomes("gemini").isEmpty)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: h.base.appendingPathComponent("tmp dir").path)) ?? [], [])
    }

    // MARK: Unavailable providers

    func testUnavailableProviders() async throws {
        let h = try Harness()
        XCTAssertNil(h.driver.unavailableReason(providerID: "claude"))
        XCTAssertNil(h.driver.unavailableReason(providerID: "codex"))
        XCTAssertNil(h.driver.unavailableReason(providerID: "gemini"))
        XCTAssertEqual(h.driver.unavailableReason(providerID: "muse"), "Sign-in for Muse is not supported yet.")
        XCTAssertEqual(h.driver.unavailableReason(providerID: "other"), "Sign-in is not supported for this provider.")
        _ = h.start("muse")
        await waitUntil { !h.recorder.terminalPhases.isEmpty }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(h.recorder.phases, [.failed(message: "Sign-in for Muse is not supported yet.")])
        XCTAssertNil(h.driver.shellAlias(providerID: "muse", homePath: "/x"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.root.path))
    }

    // MARK: Managed root containment

    func testCleanupNeverEscapesManagedRoot() throws {
        let h = try Harness()
        let fm = FileManager.default
        let root = h.root.path
        let outside = h.base.appendingPathComponent("outside").path
        try fm.createDirectory(atPath: outside + "/keep", withIntermediateDirectories: true)
        try "precious".write(toFile: outside + "/keep/file", atomically: true, encoding: .utf8)
        try fm.createDirectory(atPath: root + "/claude/legit", withIntermediateDirectories: true)

        // Symlink inside the root that points outside.
        try fm.createSymbolicLink(atPath: root + "/claude/evil", withDestinationPath: outside)
        XCTAssertFalse(h.driver.isManagedHome(root + "/claude/evil"))
        h.driver.removeManagedHome(at: root + "/claude/evil")
        h.driver.removeManagedHome(at: root + "/claude/evil/keep")
        XCTAssertTrue(fm.fileExists(atPath: outside + "/keep/file"))

        // `..` that climbs out, both through existing and missing components.
        for p in [root + "/claude/legit/../../../../outside", root + "/claude/legit/../../../../outside/keep",
                  root + "/claude/missing/../../../../outside/keep", root + "/../accounts/../../outside"] {
            XCTAssertFalse(h.driver.isManagedHome(p), p)
            h.driver.removeManagedHome(at: p)
        }
        XCTAssertTrue(fm.fileExists(atPath: outside + "/keep/file"))

        // The root itself, a provider folder and unrelated paths are never removed.
        for p in [root, root + "/", root + "/claude", "/", "relative/path", outside] {
            h.driver.removeManagedHome(at: p)
        }
        XCTAssertTrue(fm.fileExists(atPath: root + "/claude/legit"))
        XCTAssertFalse(h.driver.isManagedHome(root))
        XCTAssertFalse(h.driver.isManagedHome(root + "/../accounts"))
        XCTAssertTrue(h.driver.isManagedHome(root + "/claude"))
        XCTAssertTrue(h.driver.isManagedHome(root + "/claude/not-yet-created"))

        // A managed home holding a symlink to the outside: the link goes, the target stays.
        try fm.createSymbolicLink(atPath: root + "/claude/legit/link", withDestinationPath: outside + "/keep")
        h.driver.removeManagedHome(at: root + "/claude/legit/../legit")
        XCTAssertFalse(fm.fileExists(atPath: root + "/claude/legit"))
        XCTAssertTrue(fm.fileExists(atPath: outside + "/keep/file"))

        // A managed root reached through a symlink still contains its own children only.
        let alias = h.base.appendingPathComponent("root-alias").path
        try fm.createSymbolicLink(atPath: alias, withDestinationPath: root)
        try fm.createDirectory(atPath: root + "/codex/abc", withIntermediateDirectories: true)
        let viaAlias = CLILoginDriver(managedRoot: URL(fileURLWithPath: alias), fileSystem: SystemLoginFileSystem(),
                                      launcher: FakeLauncher(), clock: ManualClock(),
                                      environment: LoginEnvironment(variables: [:], homeDirectory: h.home))
        XCTAssertTrue(viaAlias.isManagedHome(root + "/codex/abc"))
        viaAlias.removeManagedHome(at: alias + "/codex/abc")
        XCTAssertFalse(fm.fileExists(atPath: root + "/codex/abc"))
        XCTAssertTrue(fm.fileExists(atPath: outside + "/keep/file"))
        XCTAssertTrue(fm.fileExists(atPath: root))
    }

    // MARK: Quoting

    func testShellAliasQuoting() throws {
        let h = try Harness()
        let spaced = "/Users/me/Library/Application Support/TokenBar/accounts/codex/1a2b3c4d-0000"
        XCTAssertEqual(h.driver.shellAlias(providerID: "codex", homePath: spaced),
                       "alias codex-1a2b3c='CODEX_HOME=\"\(spaced)\" codex'")
        XCTAssertEqual(h.driver.shellAlias(providerID: "claude", homePath: "/a b/x"),
                       "alias claude-x='CLAUDE_CONFIG_DIR=\"/a b/x\" claude'")
        XCTAssertNil(h.driver.shellAlias(providerID: "gemini", homePath: "/a/not-dot-gemini"))
        XCTAssertNil(h.driver.shellAlias(providerID: "codex", homePath: "relative"))

        // Evaluate the aliases in a real shell with a stand-in CLI that prints its home variable.
        let bin = h.base.appendingPathComponent("aliasbin").path
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        for (name, variable) in [("codex", "CODEX_HOME"), ("claude", "CLAUDE_CONFIG_DIR")] {
            let p = bin + "/" + name
            try "#!/bin/sh\nprintf '%s' \"$\(variable)\"\n".write(toFile: p, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p)
        }
        let tricky = [spaced, "/tmp/it's a \"dir\" $HOME `x` \\ !1/abc", "/tmp/o'neil/codex"]
        for (provider, path) in [("codex", tricky[0]), ("codex", tricky[1]), ("claude", tricky[1]), ("claude", tricky[2])] {
            let alias = try XCTUnwrap(h.driver.shellAlias(providerID: provider, homePath: path))
            let name = String(alias.dropFirst("alias ".count).prefix { $0 != "=" })
            let out = try runShell("/bin/bash", ["-c", "shopt -s expand_aliases\n\(alias)\n\(name)\n"], path: bin)
            XCTAssertEqual(out, path, alias)
        }
    }

    func testCommandScriptQuoting() throws {
        let base = try TestSupport.tempDir()
        let weird = base.appendingPathComponent("Application Support/it's \"here\" $x").path
        let home = weird + "/gemini/abc"
        let binDir = weird + "/bin dir"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        let binary = binDir + "/gem'ini"
        try "#!/bin/sh\nprintf '%s|%s|%s' \"$GEMINI_CLI_HOME\" \"$(pwd)\" \"${GEMINI_FORCE_ENCRYPTED_FILE_STORAGE-unset}\"\n"
            .write(toFile: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary)
        let scriptDir = weird + "/script dir"
        try FileManager.default.createDirectory(atPath: scriptDir, withIntermediateDirectories: true)
        let scriptPath = scriptDir + "/Sign in to Gemini CLI.command"
        let script = ShellText.terminalScript(scriptPath: scriptPath, pidPath: scriptDir + "/pid", launchHome: home,
                                              binary: binary, homeVariable: "GEMINI_CLI_HOME",
                                              unsetVariables: ["GEMINI_FORCE_ENCRYPTED_FILE_STORAGE"],
                                              pathPrefix: [binDir], displayName: "Gemini CLI")
        try SystemLoginFileSystem().writeFile(scriptPath, contents: Data(script.utf8), mode: 0o700)
        XCTAssertEqual(mode(scriptPath), 0o700)
        let out = try runShell(scriptPath, [], path: "/usr/bin:/bin", extraEnv: ["GEMINI_FORCE_ENCRYPTED_FILE_STORAGE": "true"])
        let realHome = SystemLoginFileSystem().realPath(home)!
        // The shell reports its directory as it was spelled; on macOS the temporary folder sits behind a
        // symbolic link (/var -> /private/var), so compare the resolved paths.
        let parts = out.components(separatedBy: "|")
        XCTAssertEqual(parts.count, 3, out)
        XCTAssertEqual(parts.first, home)
        XCTAssertEqual(parts.count > 1 ? SystemLoginFileSystem().realPath(parts[1]) : nil, realHome)
        XCTAssertEqual(parts.last, "unset")
        XCTAssertFalse(FileManager.default.fileExists(atPath: scriptPath), "script deletes itself")
        let pid = try String(contentsOfFile: scriptDir + "/pid", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotNil(Int32(pid))
    }

    private func runShell(_ executable: String, _ args: [String], path: String,
                          extraEnv: [String: String] = [:]) throws -> String {
        var env = ["PATH": path + ":/usr/bin:/bin", "HOME": NSTemporaryDirectory()]
        env.merge(extraEnv) { $1 }
        let result = SystemLoginProcessLauncher().run(
            LoginLaunchSpec(executable: executable, arguments: args, environment: env), timeout: 10)
        let r = try XCTUnwrap(result)
        XCTAssertEqual(r.status, 0)
        return r.output
    }

    func testSystemLauncherRunsAndTimesOut() throws {
        let launcher = SystemLoginProcessLauncher()
        let ok = launcher.run(LoginLaunchSpec(executable: "/bin/sh", arguments: ["-c", "echo one; echo /bin/sh"],
                                              environment: [:]), timeout: 5)
        XCTAssertEqual(ok, LoginRunResult(status: 0, output: "one\n/bin/sh\n"))
        let started = Date()
        XCTAssertNil(launcher.run(LoginLaunchSpec(executable: "/bin/sh", arguments: ["-c", "sleep 30"], environment: [:]),
                                  timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertNil(launcher.run(LoginLaunchSpec(executable: "/nonexistent", arguments: [], environment: [:]), timeout: 1))

        // A launched child sees an open stdin, is terminated on request and reports its exit.
        let exited = expectation(description: "exit")
        let child = try launcher.launch(LoginLaunchSpec(executable: "/bin/sh", arguments: ["-c", "read line; exit 3"],
                                                        environment: [:])) { _ in exited.fulfill() }
        usleep(200_000)
        child.terminate()
        child.terminate()
        wait(for: [exited], timeout: 5)
    }
}
