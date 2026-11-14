import Foundation

/// Where each CLI keeps its home directory and how to recognise one.
///
/// - Claude Code: `CLAUDE_CONFIG_DIR` (default `~/.claude`; older installs `~/.config/claude`).
/// - Codex: `CODEX_HOME` (default `~/.codex`).
/// - Gemini CLI: `GEMINI_CLI_HOME` replaces the *home* directory; the data lives in `$GEMINI_CLI_HOME/.gemini`.
/// - Muse Code: `MUSE_SESSIONS_DIR`, else `$XDG_DATA_HOME/muse/sessions`, else `~/.local/share/muse/sessions`.
public struct ProviderHomeRule: Sendable {
    public let providerID: String
    /// Environment variables that point at a home, and the suffix that turns their value into the data path.
    public let variables: [(name: String, suffix: String)]
    /// Data path inside a TokenBar-managed home directory (Gemini: `<home>/.gemini`).
    public let managedSuffix: String
    let defaults: @Sendable (_ home: String, _ env: [String: String]) -> [String]
    /// Directories whose entries starting with a prefix are sibling profiles, e.g. `~/.claude-work`.
    let siblings: @Sendable (_ home: String) -> [(dir: String, prefix: String)]
    let looksLikeHome: @Sendable (_ path: String, _ fs: FileSystem) -> Bool

    public static let all: [ProviderHomeRule] = [claude, codex, gemini, muse]

    public static func rule(for providerID: String) -> ProviderHomeRule? {
        all.first { $0.providerID == providerID }
    }

    public func isHome(_ path: String, fileSystem: FileSystem) -> Bool {
        fileSystem.isDirectory(path) && looksLikeHome(path, fileSystem)
    }

    public func defaultPaths(home: String, environment: [String: String]) -> [String] {
        defaults(home, environment)
    }

    static let claude = ProviderHomeRule(
        providerID: "claude",
        variables: [("CLAUDE_CONFIG_DIR", "")],
        managedSuffix: "",
        defaults: { home, env in
            var p = [home + "/.claude", home + "/.config/claude"]
            if let xdg = env["XDG_CONFIG_HOME"], xdg.hasPrefix("/") { p.append(xdg + "/claude") }
            return p
        },
        siblings: { home in [(home, ".claude-"), (home, ".claude_"), (home + "/.config", "claude-")] },
        looksLikeHome: { path, fs in
            if fs.isDirectory(path + "/projects") || fs.fileExists(path + "/.credentials.json") { return true }
            // A signed-in profile that has not been used yet only has its account file.
            for file in [path + "/.claude.json", path + "/.config.json"] {
                if let d = fs.contents(of: file, maxBytes: AccountIdentityReader.maxConfigBytes), d.containsASCII("\"oauthAccount\"") { return true }
            }
            return false
        })

    static let codex = ProviderHomeRule(
        providerID: "codex",
        variables: [("CODEX_HOME", "")],
        managedSuffix: "",
        defaults: { home, _ in [home + "/.codex"] },
        siblings: { home in [(home, ".codex-"), (home, ".codex_")] },
        looksLikeHome: { path, fs in
            fs.isDirectory(path + "/sessions") || fs.isDirectory(path + "/archived_sessions") || fs.fileExists(path + "/auth.json")
        })

    static let gemini = ProviderHomeRule(
        providerID: "gemini",
        variables: [("GEMINI_CLI_HOME", "/.gemini")],
        managedSuffix: "/.gemini",
        defaults: { home, _ in [home + "/.gemini"] },
        siblings: { home in [(home, ".gemini-"), (home, ".gemini_")] },
        looksLikeHome: { path, fs in
            fs.isDirectory(path + "/tmp") || fs.fileExists(path + "/oauth_creds.json") || fs.fileExists(path + "/google_accounts.json")
        })

    static let muse = ProviderHomeRule(
        providerID: "muse",
        variables: [("MUSE_SESSIONS_DIR", "")],
        managedSuffix: "",
        defaults: { home, env in
            var p: [String] = []
            if let xdg = env["XDG_DATA_HOME"], xdg.hasPrefix("/") { p.append(xdg + "/muse/sessions") }
            p.append(home + "/.local/share/muse/sessions")
            return p
        },
        siblings: { _ in [] },
        looksLikeHome: { path, fs in
            // Sessions are stored as YYYY/MM/DD/<id>/session.jsonl; a year folder is enough evidence.
            fs.entries(of: path).contains { $0.count == 4 && Int($0) != nil }
        })
}
