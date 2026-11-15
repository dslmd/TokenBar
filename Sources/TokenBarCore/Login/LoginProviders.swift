import Foundation

/// How each official CLI signs in when its home is relocated. Sources are listed in the
/// report that accompanied this module; the short version:
///
/// - Codex: `codex login` starts a local callback server, opens the browser itself and exits 0
///   once `$CODEX_HOME/auth.json` is written (default credential store is "file"). No TTY needed.
/// - Claude Code: `claude auth login --claudeai` opens the browser, waits for the localhost
///   callback and exits 0. `CLAUDE_CONFIG_DIR` relocates the config; on macOS the tokens go to
///   the Keychain item `Claude Code-credentials-<sha256(config dir) prefix 8>`, elsewhere (or when
///   the Keychain refuses the write) to `<dir>/.credentials.json`. The account profile is
///   written to `<dir>/.claude.json` (`oauthAccount`).
/// - Gemini CLI: no sign-in subcommand; the interactive UI runs the Google sign-in at startup when
///   `security.auth.selectedType` is `oauth-personal`, so it needs a TTY (Terminal).
///   `GEMINI_CLI_HOME` replaces the home directory, so files land in `$GEMINI_CLI_HOME/.gemini`.
struct LoginProviderSpec: Sendable {
    enum Mode: Sendable {
        /// Runs as a plain child process with these arguments.
        case childProcess(arguments: [String])
        /// Needs a TTY: opened in Terminal through a `.command` script.
        case terminal
    }

    enum Signal: Sendable {
        case codex, claude, gemini
    }

    let id: String
    let displayName: String
    let binaryName: String
    let installCommand: String
    let homeVariable: String
    let mode: Mode
    /// Variables removed from the child's environment because they would redirect or bypass the sign-in.
    let unsetVariables: [String]
    /// Path inside the launch home that TokenBar registers as the account (nil: the launch home itself).
    let accountSubpath: String?
    /// Whether exit status 0 alone proves success (credentials may live outside the home, e.g. the Keychain).
    let trustsExitZero: Bool
    let extraSearchDirectories: @Sendable (_ home: String) -> [String]
    let waitingHint: String
    let signal: Signal

    var notInstalledMessage: String {
        "\(displayName) is not installed. Install it with: \(installCommand)"
    }

    static let codex = LoginProviderSpec(
        id: "codex", displayName: "Codex CLI", binaryName: "codex",
        installCommand: "npm install -g @openai/codex",
        homeVariable: "CODEX_HOME",
        mode: .childProcess(arguments: ["login"]),
        unsetVariables: [],
        accountSubpath: nil,
        trustsExitZero: false,
        extraSearchDirectories: { _ in [] },
        waitingHint: "Continue in your browser to sign in to Codex.",
        signal: .codex)

    static let claude = LoginProviderSpec(
        id: "claude", displayName: "Claude Code", binaryName: "claude",
        installCommand: "curl -fsSL https://claude.ai/install.sh | bash",
        homeVariable: "CLAUDE_CONFIG_DIR",
        mode: .childProcess(arguments: ["auth", "login", "--claudeai"]),
        unsetVariables: ["CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_REFRESH_TOKEN"],
        accountSubpath: nil,
        trustsExitZero: true,
        extraSearchDirectories: { home in [(home as NSString).appendingPathComponent(".claude/local")] },
        waitingHint: "Continue in your browser to sign in to Claude Code.",
        signal: .claude)

    static let gemini = LoginProviderSpec(
        id: "gemini", displayName: "Gemini CLI", binaryName: "gemini",
        installCommand: "npm install -g @google/gemini-cli",
        homeVariable: "GEMINI_CLI_HOME",
        mode: .terminal,
        // Forces an encrypted credential file instead of oauth_creds.json.
        unsetVariables: ["GEMINI_FORCE_ENCRYPTED_FILE_STORAGE"],
        accountSubpath: ".gemini",
        trustsExitZero: false,
        extraSearchDirectories: { _ in [] },
        waitingHint: "Continue in the Terminal window that opened, then in your browser.",
        signal: .gemini)

    static let all: [String: LoginProviderSpec] = ["codex": codex, "claude": claude, "gemini": gemini]

    static func unavailableReason(for providerID: String) -> String? {
        switch providerID {
        case "codex", "claude", "gemini": return nil
        case "muse": return "Sign-in for Muse is not supported yet."
        default: return "Sign-in is not supported for this provider."
        }
    }

    func accountPath(forLaunchHome home: String) -> String {
        accountSubpath.map { (home as NSString).appendingPathComponent($0) } ?? home
    }

    /// Files written into the launch home before the CLI starts.
    func preparationFiles(launchHome home: String) -> [(path: String, contents: Data, mode: Int)] {
        guard signal == .gemini else { return [] }
        // Gemini CLI starts the Google sign-in at launch when this auth type is selected.
        let settings = #"{"security":{"auth":{"selectedType":"oauth-personal"}}}"# + "\n"
        return [((home as NSString).appendingPathComponent(".gemini/settings.json"), Data(settings.utf8), 0o600)]
    }

    /// Whether the CLI has written credentials that TokenBar can see inside the launch home.
    func credentialsPresent(launchHome home: String, fileSystem fs: LoginFileSystem,
                            keychainProbe: (@Sendable (String) -> Bool)?) -> Bool {
        func json(_ sub: String) -> [String: Any]? {
            fs.readFile((home as NSString).appendingPathComponent(sub)).flatMap(JSON.object)
        }
        func nonEmpty(_ v: Any?) -> Bool { JSON.string(v) != nil }
        switch signal {
        case .codex:
            guard let auth = json("auth.json") else { return false }
            if let tokens = auth["tokens"] as? [String: Any], !tokens.isEmpty { return true }
            return nonEmpty(auth["OPENAI_API_KEY"])
        case .gemini:
            guard let creds = json(".gemini/oauth_creds.json") else { return false }
            return nonEmpty(creds["refresh_token"]) || nonEmpty(creds["access_token"])
        case .claude:
            if let creds = json(".credentials.json"), let oauth = creds["claudeAiOauth"] as? [String: Any],
               nonEmpty(oauth["accessToken"]) {
                return true
            }
            // `.claude.json` gets its oauthAccount before the tokens are saved, so it is not a signal: finishing
            // on it stopped claude before it wrote the credentials (seen on a real Mac). Success comes from the
            // saved credentials or from claude exiting normally (trustsExitZero).
            if let probe = keychainProbe {
                return probe(CLILoginDriver.claudeKeychainService(forConfigDirectory: home))
            }
            return false
        }
    }
}

// MARK: - Shell text

enum ShellText {
    /// POSIX single-quoting: safe for any byte sequence except NUL.
    static func singleQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// `alias codex-1a2b3c='CODEX_HOME="/path with spaces" codex'`, falling back to full
    /// single-quote escaping when the path has characters that double quotes would not protect.
    static func alias(name: String, variable: String, home: String, command: String) -> String {
        let unsafeInDoubleQuotes: Set<Character> = ["'", "\"", "$", "`", "\\", "!", "\n", "\r"]
        if !home.contains(where: unsafeInDoubleQuotes.contains) {
            return "alias \(name)='\(variable)=\"\(home)\" \(command)'"
        }
        let inner = "\(variable)=\(singleQuoted(home)) \(command)"
        return "alias \(name)=\(singleQuoted(inner))"
    }

    /// The `.command` script Terminal runs for CLIs that need a TTY. It deletes itself, records
    /// its PID (kept by `exec`) so TokenBar can stop the CLI on cancel, and runs the CLI with the
    /// managed home. Every interpolated value is single-quoted.
    static func terminalScript(scriptPath: String, pidPath: String, launchHome: String, binary: String,
                               homeVariable: String, unsetVariables: [String], pathPrefix: [String],
                               displayName: String) -> String {
        var lines = [
            "#!/bin/sh",
            "# Created by TokenBar to sign in to another \(displayName) account. It deletes itself.",
            "rm -f -- \(singleQuoted(scriptPath))",
            "echo \"$$\" > \(singleQuoted(pidPath))",
            "cd -- \(singleQuoted(launchHome)) || exit 1",
        ]
        for name in unsetVariables { lines.append("unset \(name)") }
        if !pathPrefix.isEmpty {
            lines.append("PATH=\(singleQuoted(pathPrefix.joined(separator: ":"))):\"$PATH\"")
            lines.append("export PATH")
        }
        lines.append("\(homeVariable)=\(singleQuoted(launchHome))")
        lines.append("export \(homeVariable)")
        lines.append("exec \(singleQuoted(binary))")
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Managed root containment

struct ManagedRoot: Sendable {
    let rootPath: String
    let fileSystem: LoginFileSystem

    /// Physical path for `path`: the deepest existing ancestor is resolved with realpath
    /// (symlinks and `..`), the rest is appended. Nil for relative paths, or when a
    /// not-yet-existing remainder contains `..`.
    func canonical(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        if let real = fileSystem.realPath(path) { return real }
        var components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var remainder: [String] = []
        while !components.isEmpty {
            remainder.insert(components.removeLast(), at: 0)
            let ancestor = "/" + components.joined(separator: "/")
            if let real = fileSystem.realPath(ancestor) {
                var result = real
                for c in remainder {
                    if c == "." { continue }
                    if c == ".." { return nil }
                    result = result == "/" ? "/" + c : result + "/" + c
                }
                return result
            }
        }
        return nil
    }

    /// Path components of `path` below the root, or nil when it is not strictly inside.
    func relativeComponents(_ path: String) -> [String]? {
        guard let root = canonical(rootPath), let target = canonical(path) else { return nil }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard target.hasPrefix(prefix), target.count > prefix.count else { return nil }
        return target.dropFirst(prefix.count).split(separator: "/").map(String.init)
    }

    func contains(_ path: String) -> Bool { relativeComponents(path) != nil }

    /// The `<root>/<provider>/<id>` directory that holds `path`, when `path` is at that depth or deeper.
    func accountDirectory(containing path: String) -> String? {
        guard let parts = relativeComponents(path), parts.count >= 2, let root = canonical(rootPath) else { return nil }
        return (root as NSString).appendingPathComponent("\(parts[0])/\(parts[1])")
    }

    /// Removes the account directory holding `path`. Never touches anything outside the root.
    func removeAccountDirectory(containing path: String) {
        guard let dir = accountDirectory(containing: path) else { return }
        // Re-check the exact path being removed right before removing it.
        guard let real = fileSystem.realPath(dir), real == dir, contains(real) else { return }
        try? fileSystem.removeItem(real)
    }
}
