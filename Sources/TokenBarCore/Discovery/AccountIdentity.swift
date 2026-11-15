import Foundation

/// Who is signed in to a CLI profile, as far as it can be read from local plain-text files without
/// network access or Keychain prompts. Never holds token values.
public struct AccountIdentity: Equatable, Sendable {
    public var email: String?
    /// Plan or tier as stored by the CLI, e.g. "pro" or "max".
    public var plan: String?
    public var organization: String?
    /// True when the files show a completed sign-in (even if no email is stored).
    public var isSignedIn: Bool

    public init(email: String? = nil, plan: String? = nil, organization: String? = nil, isSignedIn: Bool = false) {
        self.email = email
        self.plan = plan
        self.organization = organization
        self.isSignedIn = isSignedIn
    }

    /// Short plan label for the UI, e.g. "Pro" or "Max".
    public var planLabel: String? {
        guard let p = plan?.trimmingCharacters(in: .whitespaces), !p.isEmpty else { return nil }
        // Plan codes written as one word (Codex stores "prolite").
        if let known = Self.joinedPlanCodes[p.lowercased()] { return known }
        let words = p.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").split(separator: " ")
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

extension AccountIdentity {
    static let joinedPlanCodes = ["prolite": "Pro Lite", "proplus": "Pro Plus", "maxplus": "Max Plus"]

    /// Claude names a personal organization "<email>'s Organization"; that repeats the email and says nothing.
    static func meaningfulOrganization(_ name: String?, email: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        if let email, name.caseInsensitiveCompare("\(email)'s Organization") == .orderedSame { return nil }
        return name
    }
}

/// Extracts identities from each CLI's own files. Unknown or malformed files simply yield less information.
public enum AccountIdentityReader {
    static let maxConfigBytes = 32 * 1024 * 1024

    public static func read(providerID: String, dataPath: String, fileSystem fs: FileSystem) -> AccountIdentity? {
        switch providerID {
        case "claude": return claude(dataPath: dataPath, fs: fs)
        case "codex": return codex(dataPath: dataPath, fs: fs)
        case "gemini": return gemini(dataPath: dataPath, fs: fs)
        default: return nil
        }
    }

    /// Claude Code keeps the signed-in account in `.claude.json` (`oauthAccount.emailAddress`): inside the
    /// config directory when `CLAUDE_CONFIG_DIR` is set, in the home directory for the default `~/.claude`.
    /// A `.config.json` in the config directory takes precedence. The plan is `subscriptionType` in
    /// `.credentials.json` when that file exists (on macOS it usually lives in the Keychain, which is not read here).
    static func claude(dataPath: String, fs: FileSystem) -> AccountIdentity? {
        var configFiles = [dataPath + "/.config.json", dataPath + "/.claude.json"]
        if fs.resolvedPath(dataPath) == fs.resolvedPath(fs.homeDirectory + "/.claude") {
            configFiles.insert(fs.homeDirectory + "/.claude.json", at: 1)
        }
        var identity = AccountIdentity()
        for file in configFiles {
            guard let data = fs.contents(of: file, maxBytes: maxConfigBytes), let root = JSON.object(data),
                  let account = root["oauthAccount"] as? [String: Any] else { continue }
            identity.email = JSON.string(account["emailAddress"])
            identity.organization = AccountIdentity.meaningfulOrganization(JSON.string(account["organizationName"]), email: identity.email)
            identity.isSignedIn = identity.email != nil || JSON.string(account["accountUuid"]) != nil
            break
        }
        if let data = fs.contents(of: dataPath + "/.credentials.json", maxBytes: 1024 * 1024), let root = JSON.object(data),
           let oauth = root["claudeAiOauth"] as? [String: Any] {
            identity.plan = JSON.string(oauth["subscriptionType"])
            if JSON.string(oauth["accessToken"]) != nil { identity.isSignedIn = true }
        }
        return identity == AccountIdentity() ? nil : identity
    }

    /// Codex: `auth.json` → `tokens.id_token`, a JWT whose payload carries `email` (or
    /// `https://api.openai.com/profile.email`) and `https://api.openai.com/auth.chatgpt_plan_type`.
    /// The signature is not checked: this is only used for a display name.
    static func codex(dataPath: String, fs: FileSystem) -> AccountIdentity? {
        guard let data = fs.contents(of: dataPath + "/auth.json", maxBytes: 1024 * 1024), let root = JSON.object(data) else { return nil }
        var identity = AccountIdentity()
        if let tokens = root["tokens"] as? [String: Any] {
            identity.isSignedIn = JSON.string(tokens["access_token"]) != nil || JSON.string(tokens["refresh_token"]) != nil
            if let jwt = JSON.string(tokens["id_token"]), let claims = jwtPayload(jwt) {
                identity.email = JSON.string(claims["email"])
                    ?? (claims["https://api.openai.com/profile"] as? [String: Any]).flatMap { JSON.string($0["email"]) }
                identity.plan = (claims["https://api.openai.com/auth"] as? [String: Any]).flatMap { JSON.string($0["chatgpt_plan_type"]) }
            }
        } else if JSON.string(root["OPENAI_API_KEY"]) != nil {
            identity.isSignedIn = true
            identity.plan = "API key"
        }
        return identity == AccountIdentity() ? nil : identity
    }

    /// Gemini CLI: `google_accounts.json` → `active` (the signed-in Google account), plus `oauth_creds.json`.
    static func gemini(dataPath: String, fs: FileSystem) -> AccountIdentity? {
        var identity = AccountIdentity()
        if let data = fs.contents(of: dataPath + "/google_accounts.json", maxBytes: 1024 * 1024), let root = JSON.object(data) {
            identity.email = JSON.string(root["active"])
        }
        identity.isSignedIn = identity.email != nil || fs.fileExists(dataPath + "/oauth_creds.json")
        return identity == AccountIdentity() ? nil : identity
    }

    static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        return Data(base64Encoded: b64).flatMap { JSON.object($0) }
    }
}
