import Foundation

/// How an account got into TokenBar.
public enum AccountOrigin: String, Codable, Sendable {
    /// Found automatically on this Mac.
    case detected
    /// Created by "Sign in to another account" in a TokenBar-managed home.
    case signedIn
    /// Added by hand with a folder path.
    case manual

    public var label: String {
        switch self {
        case .detected: return "Detected"
        case .signedIn: return "Signed in here"
        case .manual: return "Added manually"
        }
    }
}

/// One CLI profile found on disk.
public struct DiscoveredAccount: Equatable, Sendable {
    public var providerID: String
    /// Normalised path as the user would write it (symlinks kept).
    public var dataPath: String
    /// Symlink-resolved path, the identity used for de-duplication.
    public var resolvedPath: String
    public var origin: AccountOrigin
    public var suggestedName: String
    public var identity: AccountIdentity?
    /// Short English note on where it was found, e.g. "CODEX_HOME in .zshrc".
    public var foundVia: String

    public var key: String { AccountKey.make(providerID: providerID, resolvedPath: resolvedPath) }
}

public enum AccountKey {
    public static func make(providerID: String, resolvedPath: String) -> String { providerID + "|" + resolvedPath }

    public static func of(_ account: Account, fileSystem fs: FileSystem) -> String {
        make(providerID: account.providerID, resolvedPath: fs.resolvedPath(normalizedPath(account.dataPath, home: fs.homeDirectory)))
    }
}

/// Zero-configuration account detection: default homes, sibling profile folders, variables from the
/// process environment and from shell start-up files, and TokenBar-managed sign-in homes.
/// Only directories that actually look like the provider's home (logs or sign-in files) are reported.
public struct AccountDiscovery: Sendable {
    public var fileSystem: FileSystem
    public var environment: [String: String]
    /// Root of TokenBar-managed homes; its layout is `<root>/<provider id>/<home>`.
    public var managedRoot: String?
    public var isManagedHome: @Sendable (String) -> Bool
    public var rules: [ProviderHomeRule]

    public init(fileSystem: FileSystem = LocalFileSystem(),
                environment: [String: String] = ProcessInfo.processInfo.environment,
                managedRoot: String? = nil,
                isManagedHome: @escaping @Sendable (String) -> Bool = { _ in false },
                rules: [ProviderHomeRule] = ProviderHomeRule.all) {
        self.fileSystem = fileSystem
        self.environment = environment
        self.managedRoot = managedRoot
        self.isManagedHome = isManagedHome
        self.rules = rules
    }

    private struct Candidate {
        var path: String
        var via: String
        var label: String?
        var managed: Bool
    }

    public func discover() -> [DiscoveredAccount] {
        let fs = fileSystem
        let home = fs.homeDirectory
        let variableNames = Set(rules.flatMap { $0.variables.map(\.name) })
        let hints = ShellProfileParser.hints(variables: variableNames, fileSystem: fs)

        var out: [DiscoveredAccount] = []
        for rule in rules {
            var candidates: [Candidate] = []
            for v in rule.variables {
                if let value = environment[v.name], value.hasPrefix("/") || value.hasPrefix("~") {
                    candidates.append(Candidate(path: normalizedPath(value, home: home) + v.suffix, via: v.name, label: nil, managed: false))
                }
                for h in hints where h.name == v.name {
                    let file = (h.file as NSString).lastPathComponent
                    candidates.append(Candidate(path: h.value + v.suffix, via: "\(v.name) in \(file)", label: h.label, managed: false))
                }
            }
            for p in rule.defaultPaths(home: home, environment: environment) {
                candidates.append(Candidate(path: p, via: "Default location", label: nil, managed: false))
            }
            for s in rule.siblings(home) {
                for name in fs.entries(of: s.dir).sorted() where name.hasPrefix(s.prefix) && name.count > s.prefix.count {
                    let path = s.dir + "/" + name
                    candidates.append(Candidate(path: path, via: "Profile folder", label: nil, managed: false))
                    if !rule.managedSuffix.isEmpty {
                        candidates.append(Candidate(path: path + rule.managedSuffix, via: "Profile folder", label: nil, managed: false))
                    }
                }
            }
            if let root = managedRoot {
                let dir = root + "/" + rule.providerID
                for name in fs.entries(of: dir).sorted() where !name.hasPrefix(".") {
                    candidates.append(Candidate(path: dir + "/" + name + rule.managedSuffix, via: "Signed in with TokenBar", label: nil, managed: true))
                }
            }

            var seen = Set<String>()
            var found: [DiscoveredAccount] = []
            for c in candidates {
                let path = normalizedPath(c.path, home: home)
                guard path.hasPrefix("/"), rule.isHome(path, fileSystem: fs) else { continue }
                let resolved = fs.resolvedPath(path)
                guard seen.insert(resolved).inserted else { continue }
                let managed = c.managed || isManaged(path) || isManaged(resolved)
                let identity = AccountIdentityReader.read(providerID: rule.providerID, dataPath: path, fileSystem: fs)
                // An abandoned managed sign-in (no credentials yet) is not an account.
                if managed && identity?.isSignedIn != true { continue }
                found.append(DiscoveredAccount(
                    providerID: rule.providerID, dataPath: path, resolvedPath: resolved,
                    origin: managed ? .signedIn : .detected,
                    suggestedName: "", identity: identity, foundVia: c.via))
                found[found.count - 1].suggestedName = AccountNaming.name(for: path, providerID: rule.providerID, identity: identity,
                                                                         label: c.label, managed: managed, home: home)
            }
            AccountNaming.disambiguate(&found, home: home)
            out += found
        }
        return out
    }

    private func isManaged(_ path: String) -> Bool {
        if isManagedHome(path) { return true }
        guard let root = managedRoot else { return false }
        return path.hasPrefix(root + "/")
    }
}

/// Automatic account names: the signed-in email, else the alias the profile is used with, else the folder.
public enum AccountNaming {
    public static func name(for path: String, providerID: String, identity: AccountIdentity?, label: String?,
                            managed: Bool, home: String) -> String {
        if let email = identity?.email { return email }
        if let label, !label.isEmpty { return label }
        if managed { return "Signed-in account" }
        return folderName(path, providerID: providerID, home: home)
    }

    /// `~/.claude` → "Default", `~/.claude-work` → "claude-work", `/x/work/.gemini` → "work".
    public static func folderName(_ path: String, providerID: String, home: String) -> String {
        var p = path
        if providerID == "gemini" && (p as NSString).lastPathComponent == ".gemini" {
            p = (p as NSString).deletingLastPathComponent
            if p == home { return "Default" }
        }
        if providerID == "muse" { return p.hasSuffix("/.local/share/muse/sessions") ? "Default" : (p as NSString).lastPathComponent }
        var last = (p as NSString).lastPathComponent
        if last.hasPrefix(".") { last.removeFirst() }
        let defaults: Set<String> = ["claude", "codex", "gemini"]
        if defaults.contains(last) {
            let parent = (p as NSString).deletingLastPathComponent
            return parent == home ? "Default" : "\(last) (\((parent as NSString).lastPathComponent))"
        }
        return last.isEmpty ? path : last
    }

    /// Two profiles signed in to the same account get the folder appended so they stay distinguishable.
    static func disambiguate(_ accounts: inout [DiscoveredAccount], home: String) {
        let counts = Dictionary(grouping: accounts.indices, by: { accounts[$0].suggestedName })
        for (_, indices) in counts where indices.count > 1 {
            for i in indices {
                let folder = folderName(accounts[i].dataPath, providerID: accounts[i].providerID, home: home)
                if folder != accounts[i].suggestedName { accounts[i].suggestedName += " · " + folder }
            }
        }
    }
}

/// Folds discovery results into the saved config: new accounts appear, removed ones stay removed,
/// the same directory is never listed twice, and automatic names follow the signed-in identity.
public enum AccountReconciler {
    /// Returns true when the config changed.
    @discardableResult
    public static func merge(_ discovered: [DiscoveredAccount], into config: inout AppConfig, fileSystem fs: FileSystem) -> Bool {
        let before = config
        // Drop duplicates of the same directory (symlinks, trailing slashes) that older versions could create.
        var seen = Set<String>()
        config.accounts = config.accounts.filter { a in
            a.dataPath.isEmpty || seen.insert(AccountKey.of(a, fileSystem: fs)).inserted
        }
        let dismissed = Set(config.dismissedAccounts)
        let existing = Dictionary(config.accounts.indices.map { (AccountKey.of(config.accounts[$0], fileSystem: fs), $0) },
                                  uniquingKeysWith: { a, _ in a })
        for d in discovered {
            if let i = existing[d.key] {
                if config.accounts[i].origin == nil { config.accounts[i].origin = d.origin }
                if d.origin == .signedIn { config.accounts[i].origin = .signedIn }
                if config.accounts[i].autoNamed, !d.suggestedName.isEmpty, config.accounts[i].name != d.suggestedName {
                    config.accounts[i].name = d.suggestedName
                }
            } else if !dismissed.contains(d.key) {
                config.accounts.append(Account(providerID: d.providerID, name: d.suggestedName, dataPath: d.dataPath,
                                               origin: d.origin, autoNamed: true))
            }
        }
        return config != before
    }

    /// Removes an account and remembers its directory so detection does not add it back.
    @discardableResult
    public static func remove(_ id: UUID, from config: inout AppConfig, fileSystem fs: FileSystem) -> Account? {
        guard let i = config.accounts.firstIndex(where: { $0.id == id }) else { return nil }
        let account = config.accounts.remove(at: i)
        if !account.dataPath.isEmpty {
            let key = AccountKey.of(account, fileSystem: fs)
            if !config.dismissedAccounts.contains(key) { config.dismissedAccounts.append(key) }
        }
        return account
    }

    /// Adds (or re-enables) an account for a directory. Returns the account that now represents it.
    @discardableResult
    public static func add(providerID: String, dataPath raw: String, origin: AccountOrigin, name: String?,
                           to config: inout AppConfig, fileSystem fs: FileSystem) -> Account {
        let path = normalizedPath(raw, home: fs.homeDirectory)
        let key = AccountKey.make(providerID: providerID, resolvedPath: fs.resolvedPath(path))
        config.dismissedAccounts.removeAll { $0 == key }
        if let i = config.accounts.firstIndex(where: { $0.providerID == providerID && AccountKey.of($0, fileSystem: fs) == key }) {
            config.accounts[i].isEnabled = true
            if origin == .signedIn { config.accounts[i].origin = .signedIn }
            return config.accounts[i]
        }
        let identity = AccountIdentityReader.read(providerID: providerID, dataPath: path, fileSystem: fs)
        let auto = name == nil
        let finalName = name ?? AccountNaming.name(for: path, providerID: providerID, identity: identity, label: nil,
                                                  managed: origin == .signedIn, home: fs.homeDirectory)
        let account = Account(providerID: providerID, name: finalName, dataPath: path, origin: origin, autoNamed: auto)
        config.accounts.append(account)
        return account
    }

    /// Data path for a home directory reported by a successful managed sign-in (Gemini keeps its data in `.gemini`).
    public static func dataPath(forManagedHome homePath: String, providerID: String, fileSystem fs: FileSystem) -> String {
        let home = normalizedPath(homePath, home: fs.homeDirectory)
        guard let suffix = ProviderHomeRule.rule(for: providerID)?.managedSuffix, !suffix.isEmpty, !home.hasSuffix(suffix) else { return home }
        return home + suffix
    }
}
