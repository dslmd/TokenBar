import Foundation

/// Claude Code online quota.
///
/// Endpoint and flow follow CodexBar (docs/claude.md, ClaudeOAuthUsageFetcher.swift,
/// ClaudeOAuthCredentials.swift): `GET https://api.anthropic.com/api/oauth/usage` with
/// `Authorization: Bearer` and `anthropic-beta: oauth-2025-04-20`; renewal via
/// `POST https://platform.claude.com/v1/oauth/token` (form: grant_type, refresh_token, client_id).
/// Credentials: `<config dir>/.credentials.json`, or the Keychain item "Claude Code-credentials"
/// for the default profile; both hold `{"claudeAiOauth":{accessToken,refreshToken,expiresAt(ms),…}}`.
/// Claude Code rotates refresh tokens, so renewal always goes through the guarded write-back path.
public struct ClaudeQuotaBackend: QuotaBackend {
    public init() {}
    public let providerID = "claude"
    public let cliName = "claude"
    public let refreshPolicy = RefreshPolicy.selfRefresh

    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let keychainService = "Claude Code-credentials"

    public func credentialSources(forDataPath dataPath: String, home: URL) -> [CredentialSource] {
        let dir = URL(fileURLWithPath: dataPath)
        var sources: [CredentialSource] = [.file(dir.appendingPathComponent(".credentials.json"))]
        // The Keychain item is global, so it only belongs to the default profile.
        let defaults = [home.appendingPathComponent(".claude"), home.appendingPathComponent(".config/claude")]
            .map { $0.resolvingSymlinksInPath().path }
        if defaults.contains(dir.resolvingSymlinksInPath().path) {
            sources.append(.keychain(service: Self.keychainService))
        } else {
            // Extra profiles (CLAUDE_CONFIG_DIR): Claude Code is believed to suffix the service
            // with the first 8 hex chars of SHA-256(config dir). Not confirmed from a published
            // source; a wrong guess only means "item not found".
            var candidates = [dataPath]
            let trimmed = dataPath.count > 1 && dataPath.hasSuffix("/") ? String(dataPath.dropLast()) : dataPath + "/"
            candidates.append(trimmed)
            for c in candidates {
                sources.append(.keychain(service: "\(Self.keychainService)-\(SHA256Lite.hex(c).prefix(8))"))
            }
        }
        return sources
    }

    public func parseCredentials(_ raw: Data) -> OAuthCredentials? {
        guard let root = CredentialJSON.parse(raw), let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = JSON.string(oauth["accessToken"]) else { return nil }
        return OAuthCredentials(accessToken: token, refreshToken: JSON.string(oauth["refreshToken"]),
                                expiresAt: CredentialJSON.date(fromEpoch: oauth["expiresAt"]))
    }

    public func refreshRequest(for c: OAuthCredentials) -> HTTPRequest? {
        guard let rt = c.refreshToken else { return nil }
        return HTTPRequest(url: Self.tokenURL, method: "POST",
                           headers: ["Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"],
                           body: FormBody.encode([("grant_type", "refresh_token"), ("refresh_token", rt), ("client_id", Self.clientID)]),
                           timeout: 30)
    }

    public func applyRefresh(response: Data, to raw: Data, now: Date) -> Data? {
        guard let r = CredentialJSON.parse(response), let access = JSON.string(r["access_token"]),
              var root = CredentialJSON.parse(raw), var oauth = root["claudeAiOauth"] as? [String: Any] else { return nil }
        oauth["accessToken"] = access
        if let rt = JSON.string(r["refresh_token"]) { oauth["refreshToken"] = rt }
        if let ttl = JSON.double(r["expires_in"]), ttl > 0 {
            oauth["expiresAt"] = Int64((now.timeIntervalSince1970 + ttl) * 1000)
        }
        root["claudeAiOauth"] = oauth
        return CredentialJSON.serialize(root, like: raw)
    }

    public func fetchQuota(credentials: OAuthCredentials, http: HTTPClient, now: Date) async throws -> [QuotaWindow] {
        let req = HTTPRequest(url: Self.usageURL, headers: [
            "Authorization": "Bearer \(credentials.accessToken)",
            "Accept": "application/json",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "TokenBar/0.2",
        ])
        let data = try await get(http, req)
        return try Self.parseUsage(data)
    }

    static func parseUsage(_ data: Data) throws -> [QuotaWindow] {
        guard let root = CredentialJSON.parse(data) else { throw QuotaError.badResponse }
        let defs: [(String, String, Int?)] = [
            ("five_hour", "5 小时", 300), ("seven_day", "每周", 10080),
            ("seven_day_sonnet", "Sonnet 每周", 10080), ("seven_day_opus", "Opus 每周", 10080),
        ]
        var out: [QuotaWindow] = []
        for (key, label, minutes) in defs {
            guard let w = root[key] as? [String: Any], let used = JSON.double(w["utilization"]) else { continue }
            out.append(QuotaWindow(label: label, usedPercent: min(100, max(0, used)), windowMinutes: minutes,
                                   resetsAt: (w["resets_at"] as? String).flatMap(ISO8601.parse)))
        }
        if out.isEmpty && root["five_hour"] == nil && root["seven_day"] == nil { throw QuotaError.badResponse }
        return out
    }
}
