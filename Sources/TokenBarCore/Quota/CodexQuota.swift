import Foundation

/// Codex online quota.
///
/// CodexBar (docs/codex.md, CodexOAuthUsageFetcher.swift): `GET https://chatgpt.com/backend-api/wham/usage`
/// with `Authorization: Bearer <tokens.access_token>` and `ChatGPT-Account-Id: <tokens.account_id>`;
/// `rate_limit.primary_window` / `secondary_window` {used_percent, reset_at, limit_window_seconds}.
/// CodexBar never refreshes or rewrites Codex's `auth.json` (the CLI owns the rotating chain), and
/// neither do we: an expired login is reported and the user runs `codex` once.
public struct CodexQuotaBackend: QuotaBackend {
    public init() {}
    public let providerID = "codex"
    public let cliName = "codex"
    public let refreshPolicy = RefreshPolicy.delegateToCLI

    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    public func credentialSources(forDataPath dataPath: String, home: URL) -> [CredentialSource] {
        [.file(URL(fileURLWithPath: dataPath).appendingPathComponent("auth.json"))]
    }

    public func parseCredentials(_ raw: Data) -> OAuthCredentials? {
        guard let root = CredentialJSON.parse(raw), let tokens = root["tokens"] as? [String: Any],
              let access = JSON.string(tokens["access_token"]) else { return nil }
        return OAuthCredentials(accessToken: access, refreshToken: JSON.string(tokens["refresh_token"]),
                                expiresAt: CredentialJSON.jwtExpiry(access), accountID: JSON.string(tokens["account_id"]))
    }

    public func refreshRequest(for credentials: OAuthCredentials) -> HTTPRequest? { nil }
    public func applyRefresh(response: Data, to raw: Data, now: Date) -> Data? { nil }

    public func fetchQuota(credentials: OAuthCredentials, http: HTTPClient, now: Date) async throws -> [QuotaWindow] {
        var headers = ["Authorization": "Bearer \(credentials.accessToken)", "Accept": "application/json", "User-Agent": "TokenBar/0.2"]
        if let id = credentials.accountID { headers["ChatGPT-Account-Id"] = id }
        let data = try await get(http, HTTPRequest(url: Self.usageURL, headers: headers))
        return try Self.parseUsage(data)
    }

    static func parseUsage(_ data: Data) throws -> [QuotaWindow] {
        guard let root = CredentialJSON.parse(data), let rl = root["rate_limit"] as? [String: Any] else { throw QuotaError.badResponse }
        var out: [QuotaWindow] = []
        for (key, fallback) in [("primary_window", "主要窗口"), ("secondary_window", "次要窗口")] {
            guard let w = rl[key] as? [String: Any], let used = JSON.double(w["used_percent"]) else { continue }
            let minutes = JSON.int(w["limit_window_seconds"]) / 60
            let reset = JSON.int64(w["reset_at"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
            out.append(QuotaWindow(label: CodexParser.windowLabel(minutes: minutes > 0 ? minutes : nil, fallback: fallback),
                                   usedPercent: min(100, max(0, used)), windowMinutes: minutes > 0 ? minutes : nil, resetsAt: reset))
        }
        return out
    }
}
