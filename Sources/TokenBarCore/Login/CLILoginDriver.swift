import Foundation

/// Adds accounts by running each official CLI's own sign-in inside a TokenBar-managed home
/// (`<managedRoot>/<provider>/<uuid>`), then reporting that directory once credentials appear.
/// TokenBar never handles the OAuth flow itself.
public final class CLILoginDriver: AccountLoginDriving {
    /// Returns true when a Keychain generic-password item with this service name exists.
    /// Claude Code on macOS stores its tokens there, so the app may supply this probe; without it
    /// a Claude sign-in is still detected by `claude auth login` exiting with status 0.
    public typealias KeychainProbe = @Sendable (_ service: String) -> Bool

    public struct Options: Sendable {
        /// Give up (and clean up) after this long.
        public var timeout: TimeInterval = 600
        public var pollInterval: TimeInterval = 1
        /// After credentials appear, how long to let the CLI exit on its own before stopping it.
        public var successGrace: TimeInterval = 5
        public var loginShellPath = "/bin/zsh"
        public var loginShellTimeout: TimeInterval = 5
        public var openCommandPath = "/usr/bin/open"
        public var openTimeout: TimeInterval = 15
        /// Where per-attempt `.command` scripts are written (each in its own 0700 directory).
        public var scriptDirectory: URL = FileManager.default.temporaryDirectory

        public init() {}
    }

    public let managedRoot: URL
    private let rootPath: String
    private let fileSystem: LoginFileSystem
    private let launcher: LoginProcessLaunching
    private let clock: LoginClock
    private let environment: LoginEnvironment
    private let options: Options
    private let probe: LockedBox<KeychainProbe?>

    public convenience init(managedRoot: URL) {
        self.init(managedRoot: managedRoot, fileSystem: SystemLoginFileSystem(), launcher: SystemLoginProcessLauncher(),
                  clock: SystemLoginClock(), environment: .current, options: Options(), claudeKeychainProbe: nil)
    }

    public init(managedRoot: URL, fileSystem: LoginFileSystem, launcher: LoginProcessLaunching, clock: LoginClock,
                environment: LoginEnvironment, options: Options = Options(), claudeKeychainProbe: KeychainProbe? = nil) {
        self.managedRoot = managedRoot
        var root = managedRoot.standardizedFileURL.path
        while root.count > 1 && root.hasSuffix("/") { root.removeLast() }
        self.rootPath = root
        self.fileSystem = fileSystem
        self.launcher = launcher
        self.clock = clock
        self.environment = environment
        self.options = options
        self.probe = LockedBox(claudeKeychainProbe)
    }

    /// Lets the app supply (or replace) the Claude Keychain probe after construction.
    public func setClaudeKeychainProbe(_ probe: KeychainProbe?) {
        self.probe.set(probe)
    }

    /// Keychain service name Claude Code uses for a non-default `CLAUDE_CONFIG_DIR`:
    /// `"Claude Code-credentials-" + first 8 hex chars of SHA-256(NFC(the variable's exact value))`.
    /// The hash covers the literal string (no trailing-slash trimming, no symlink resolution).
    public static func claudeKeychainService(forConfigDirectory path: String) -> String {
        "Claude Code-credentials-" + SHA256Lite.hex(path.precomposedStringWithCanonicalMapping).prefix(8)
    }

    private var managed: ManagedRoot { ManagedRoot(rootPath: rootPath, fileSystem: fileSystem) }

    // MARK: AccountLoginDriving

    public func unavailableReason(providerID: String) -> String? {
        LoginProviderSpec.unavailableReason(for: providerID)
    }

    public func start(providerID: String, onPhase: @escaping @Sendable (LoginPhase) -> Void) -> LoginHandle {
        let attempt = LoginAttempt(onPhase: onPhase) { [self] resources, phase in
            self.cleanUp(resources, after: phase)
        }
        guard LoginProviderSpec.unavailableReason(for: providerID) == nil, let spec = LoginProviderSpec.all[providerID] else {
            attempt.finish(.failed(message: unavailableReason(providerID: providerID) ?? "Sign-in is not supported for this provider."))
            return attempt
        }
        attempt.emit(.locatingCLI)
        Task.detached { [self] in
            await self.run(spec, attempt)
        }
        return attempt
    }

    public func shellAlias(providerID: String, homePath: String) -> String? {
        guard let spec = LoginProviderSpec.all[providerID], homePath.hasPrefix("/") else { return nil }
        var home = homePath
        if let sub = spec.accountSubpath {
            // Gemini registers `<home>/.gemini`; the variable names the directory that contains it.
            var trimmed = homePath
            while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
            guard (trimmed as NSString).lastPathComponent == sub else { return nil }
            home = (trimmed as NSString).deletingLastPathComponent
        }
        // Claude keys its Keychain item to the exact CLAUDE_CONFIG_DIR string, so it is kept verbatim.
        let name = "\(spec.binaryName)-\(Self.aliasSuffix(for: home))"
        return ShellText.alias(name: name, variable: spec.homeVariable, home: home, command: spec.binaryName)
    }

    public func removeManagedHome(at homePath: String) {
        managed.removeAccountDirectory(containing: homePath)
    }

    public func isManagedHome(_ path: String) -> Bool {
        managed.contains(path)
    }

    // MARK: Flow

    private func run(_ spec: LoginProviderSpec, _ attempt: LoginAttempt) async {
        let started = clock.now()
        let locator = CLILocator(fileSystem: fileSystem, launcher: launcher, environment: environment,
                                 loginShellPath: options.loginShellPath, loginShellTimeout: options.loginShellTimeout)
        guard let binary = locator.locate(spec.binaryName,
                                          extraDirectories: spec.extraSearchDirectories(environment.homeDirectory)) else {
            attempt.finish(.failed(message: spec.notInstalledMessage))
            return
        }
        guard !attempt.isFinished else { return }

        // Managed home: <root>/<provider>/<uuid>, every level 0700.
        let providerDir = (rootPath as NSString).appendingPathComponent(spec.id)
        let launchHome = (providerDir as NSString).appendingPathComponent(UUID().uuidString.lowercased())
        do {
            try fileSystem.createPrivateDirectory(rootPath)
            try fileSystem.createPrivateDirectory(providerDir)
            try fileSystem.createPrivateDirectory(launchHome)
        } catch {
            attempt.finish(.failed(message: "Could not create a folder for the new account."))
            return
        }
        guard attempt.adoptLaunchHome(launchHome) else {
            managed.removeAccountDirectory(containing: launchHome)
            return
        }
        do {
            for file in spec.preparationFiles(launchHome: launchHome) {
                try fileSystem.createPrivateDirectory((file.path as NSString).deletingLastPathComponent)
                try fileSystem.writeFile(file.path, contents: file.contents, mode: file.mode)
            }
        } catch {
            attempt.finish(.failed(message: "Could not prepare the folder for the new account."))
            return
        }

        let pathPrefix = searchPathPrefix(for: binary)
        switch spec.mode {
        case .childProcess(let arguments):
            var env = environment.variables
            for name in spec.unsetVariables { env.removeValue(forKey: name) }
            env[spec.homeVariable] = launchHome
            env["HOME"] = env["HOME"] ?? environment.homeDirectory
            env["PATH"] = Self.joinPath(pathPrefix + (env["PATH"].map { [$0] } ?? ["/usr/bin:/bin:/usr/sbin:/sbin"]))
            let launchSpec = LoginLaunchSpec(executable: binary, arguments: arguments, environment: env,
                                             currentDirectory: launchHome)
            let child: LoginChildProcess
            do {
                child = try launcher.launch(launchSpec) { status in attempt.recordExit(status) }
            } catch {
                attempt.finish(.failed(message: "Could not start \(spec.displayName)."))
                return
            }
            guard attempt.adoptChild(child) else {
                child.terminate()
                return
            }

        case .terminal:
            let scriptDir = (options.scriptDirectory.standardizedFileURL.path as NSString)
                .appendingPathComponent("TokenBar-sign-in-\(UUID().uuidString.lowercased())")
            do { try fileSystem.createPrivateDirectory(scriptDir) } catch {
                attempt.finish(.failed(message: "Could not open Terminal."))
                return
            }
            guard attempt.adoptScriptDirectory(scriptDir) else {
                try? fileSystem.removeItem(scriptDir)
                return
            }
            let scriptPath = (scriptDir as NSString).appendingPathComponent("Sign in to \(spec.displayName).command")
            let pidPath = (scriptDir as NSString).appendingPathComponent("pid")
            let script = ShellText.terminalScript(
                scriptPath: scriptPath, pidPath: pidPath, launchHome: launchHome, binary: binary,
                homeVariable: spec.homeVariable, unsetVariables: spec.unsetVariables, pathPrefix: pathPrefix,
                displayName: spec.displayName)
            do { try fileSystem.writeFile(scriptPath, contents: Data(script.utf8), mode: 0o700) } catch {
                attempt.finish(.failed(message: "Could not open Terminal."))
                return
            }
            guard !attempt.isFinished else { return }
            let open = LoginLaunchSpec(executable: options.openCommandPath, arguments: [scriptPath],
                                       environment: environment.variables)
            guard let result = launcher.run(open, timeout: options.openTimeout), result.status == 0 else {
                attempt.finish(.failed(message: "Could not open Terminal."))
                return
            }
        }

        attempt.emit(.waitingForUser(hint: spec.waitingHint))
        await poll(spec, attempt, launchHome: launchHome, started: started)
    }

    private func poll(_ spec: LoginProviderSpec, _ attempt: LoginAttempt, launchHome: String, started: Date) async {
        let success = LoginPhase.succeeded(homePath: spec.accountPath(forLaunchHome: launchHome))
        var credentialsSeenAt: Date?
        while !attempt.isFinished {
            // Read the exit status first: a CLI writes its credentials before it exits.
            let exitStatus = attempt.exitStatus
            let present = spec.credentialsPresent(launchHome: launchHome, fileSystem: fileSystem,
                                                  keychainProbe: spec.signal == .claude ? probe.get() : nil)
            let now = clock.now()
            if present {
                if case .childProcess = spec.mode, exitStatus == nil {
                    let seen = credentialsSeenAt ?? now
                    credentialsSeenAt = seen
                    if now.timeIntervalSince(seen) >= options.successGrace {
                        attempt.finish(success)
                        return
                    }
                } else {
                    attempt.finish(success)
                    return
                }
            } else if let status = exitStatus {
                if status == 0 && spec.trustsExitZero {
                    attempt.finish(success)
                } else if status == 0 {
                    attempt.finish(.failed(message: "\(spec.displayName) finished, but no credentials were saved for the new account."))
                } else {
                    attempt.finish(.failed(message: "\(spec.displayName) sign-in did not finish (exit code \(status))."))
                }
                return
            } else if case .terminal = spec.mode, let pid = attempt.terminalPID(fileSystem: fileSystem),
                      !launcher.isProcessRunning(pid: pid) {
                attempt.finish(.failed(message: "\(spec.displayName) closed before sign-in finished."))
                return
            }
            if now.timeIntervalSince(started) >= options.timeout {
                attempt.finish(.failed(message: "Sign-in timed out. Try again."))
                return
            }
            await clock.sleep(seconds: options.pollInterval)
        }
    }

    /// Runs once per attempt, right after its single terminal phase is decided.
    private func cleanUp(_ resources: LoginAttempt.Resources, after phase: LoginPhase) {
        resources.child?.terminate()
        let succeeded: Bool
        if case .succeeded = phase { succeeded = true } else { succeeded = false }
        if let dir = resources.scriptDirectory {
            // The CLI that Terminal runs keeps going after a success (it is the user's session now).
            if !succeeded, let pid = LoginAttempt.readPID(in: dir, fileSystem: fileSystem) {
                launcher.terminateProcess(pid: pid)
            }
            if (dir as NSString).lastPathComponent.hasPrefix("TokenBar-sign-in-") {
                try? fileSystem.removeItem(dir)
            }
        }
        guard !succeeded, let home = resources.launchHome else { return }
        let managed = self.managed
        managed.removeAccountDirectory(containing: home)
        // A stopped CLI can still write for a moment; sweep once more shortly after.
        let clock = self.clock
        Task.detached {
            await clock.sleep(seconds: 2)
            managed.removeAccountDirectory(containing: home)
        }
    }

    private func searchPathPrefix(for binary: String) -> [String] {
        // npm-installed CLIs are `#!/usr/bin/env node` scripts; node usually sits next to them.
        var dirs = [(binary as NSString).deletingLastPathComponent]
        if let real = fileSystem.realPath(binary) { dirs.append((real as NSString).deletingLastPathComponent) }
        dirs += ["/opt/homebrew/bin", "/usr/local/bin"]
        var seen = Set<String>()
        return dirs.filter { seen.insert($0).inserted }
    }

    private static func joinPath(_ parts: [String]) -> String {
        var seen = Set<String>()
        return parts.flatMap { $0.split(separator: ":").map(String.init) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }

    static func aliasSuffix(for home: String) -> String {
        let last = (home as NSString).lastPathComponent.lowercased()
        let cleaned = String(last.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(6))
        return cleaned.isEmpty ? "2" : cleaned
    }
}

/// State of one sign-in attempt. The lock guarantees exactly one terminal phase; phases are
/// delivered in order on a private serial queue, never synchronously from `start` or `cancel`.
final class LoginAttempt: LoginHandle, @unchecked Sendable {
    struct Resources {
        var child: LoginChildProcess?
        var launchHome: String?
        var scriptDirectory: String?
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "TokenBar.login.phases")
    private let onPhase: @Sendable (LoginPhase) -> Void
    private let cleanup: @Sendable (Resources, LoginPhase) -> Void
    private var finished = false
    private var resources = Resources()
    private var exit: Int32?

    init(onPhase: @escaping @Sendable (LoginPhase) -> Void,
         cleanup: @escaping @Sendable (Resources, LoginPhase) -> Void) {
        self.onPhase = onPhase
        self.cleanup = cleanup
    }

    func cancel() {
        finish(.cancelled)
    }

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    var exitStatus: Int32? {
        lock.lock(); defer { lock.unlock() }
        return exit
    }

    func recordExit(_ status: Int32) {
        lock.lock(); defer { lock.unlock() }
        if exit == nil { exit = status }
    }

    /// Delivers a non-terminal phase unless the attempt already ended.
    func emit(_ phase: LoginPhase) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        let onPhase = self.onPhase
        queue.async { onPhase(phase) }
    }

    /// Ends the attempt. Only the first call wins; it cleans up and then delivers `phase`.
    @discardableResult
    func finish(_ phase: LoginPhase) -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return false
        }
        finished = true
        let owned = resources
        lock.unlock()
        cleanup(owned, phase)
        let onPhase = self.onPhase
        queue.async { onPhase(phase) }
        return true
    }

    /// Records a resource for cleanup. Returns false when the attempt already ended, in which
    /// case the caller must release the resource itself.
    func adoptLaunchHome(_ path: String) -> Bool { adopt { $0.launchHome = path } }
    func adoptScriptDirectory(_ path: String) -> Bool { adopt { $0.scriptDirectory = path } }
    func adoptChild(_ child: LoginChildProcess) -> Bool { adopt { $0.child = child } }

    private func adopt(_ body: (inout Resources) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return false }
        body(&resources)
        return true
    }

    func terminalPID(fileSystem: LoginFileSystem) -> Int32? {
        lock.lock()
        let dir = resources.scriptDirectory
        lock.unlock()
        return dir.flatMap { Self.readPID(in: $0, fileSystem: fileSystem) }
    }

    static func readPID(in directory: String, fileSystem: LoginFileSystem) -> Int32? {
        guard let data = fileSystem.readFile((directory as NSString).appendingPathComponent("pid")),
              let pid = Int32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1 else { return nil }
        return pid
    }
}
