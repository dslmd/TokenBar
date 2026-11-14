import Foundation

/// Gemini CLI online quota.
///
/// CodexBar (docs/gemini.md, GeminiStatusProbe.swift): credentials in `<gemini home>/oauth_creds.json`
/// {access_token, refresh_token, id_token, expiry_date(ms)}; project from
/// `POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`; quota from
/// `POST …/v1internal:retrieveUserQuota` {"project": id} → `buckets[] {modelId, remainingFraction, resetTime}`;
/// renewal via `POST https://oauth2.googleapis.com/token` using the Gemini CLI's own (public, installed-app)
/// OAuth client, which CodexBar and we read from the installed CLI rather than embedding.
/// Google does not rotate the refresh token, and the write-back only touches access_token,
/// expiry_date and id_token (plus refresh_token if one is ever returned).
/// Newer Gemini CLI versions may keep credentials in the Keychain instead of this file; that is not supported.
public struct GeminiQuotaBackend: QuotaBackend {
    public typealias ClientLocator = @Sendable () -> (id: String, secret: String)?

    private let locator: ClientLocator

    public init(clientLocator: @escaping ClientLocator = { GeminiOAuthClientLocator.locate() }) {
        locator = clientLocator
    }

    public let providerID = "gemini"
    public let cliName = "gemini"
    public let refreshPolicy = RefreshPolicy.selfRefresh

    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    static let quotaURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
    static let loadURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!

    public func credentialSources(forDataPath dataPath: String, home: URL) -> [CredentialSource] {
        [.file(URL(fileURLWithPath: dataPath).appendingPathComponent("oauth_creds.json"))]
    }

    public func parseCredentials(_ raw: Data) -> OAuthCredentials? {
        guard let root = CredentialJSON.parse(raw), let access = JSON.string(root["access_token"]) else { return nil }
        return OAuthCredentials(accessToken: access, refreshToken: JSON.string(root["refresh_token"]),
                                expiresAt: CredentialJSON.date(fromEpoch: root["expiry_date"]))
    }

    public func refreshRequest(for c: OAuthCredentials) -> HTTPRequest? {
        guard let rt = c.refreshToken, let client = locator() else { return nil }
        return HTTPRequest(url: Self.tokenURL, method: "POST",
                           headers: ["Content-Type": "application/x-www-form-urlencoded"],
                           body: FormBody.encode([("client_id", client.id), ("client_secret", client.secret),
                                                  ("refresh_token", rt), ("grant_type", "refresh_token")]),
                           timeout: 30)
    }

    public func applyRefresh(response: Data, to raw: Data, now: Date) -> Data? {
        guard let r = CredentialJSON.parse(response), let access = JSON.string(r["access_token"]),
              var root = CredentialJSON.parse(raw) else { return nil }
        root["access_token"] = access
        if let ttl = JSON.double(r["expires_in"]), ttl > 0 { root["expiry_date"] = Int64((now.timeIntervalSince1970 + ttl) * 1000) }
        if let id = JSON.string(r["id_token"]) { root["id_token"] = id }
        if let rt = JSON.string(r["refresh_token"]) { root["refresh_token"] = rt }
        return CredentialJSON.serialize(root)
    }

    public func fetchQuota(credentials: OAuthCredentials, http: HTTPClient, now: Date) async throws -> [QuotaWindow] {
        let auth = ["Authorization": "Bearer \(credentials.accessToken)", "Content-Type": "application/json"]
        // Project discovery is best effort; without it the quota call still works for most accounts.
        var project: String?
        if let data = try? await get(http, HTTPRequest(url: Self.loadURL, method: "POST", headers: auth,
                                                       body: Data("{\"metadata\":{\"ideType\":\"GEMINI_CLI\",\"pluginType\":\"GEMINI\"}}".utf8))),
           let obj = CredentialJSON.parse(data) {
            if let s = JSON.string(obj["cloudaicompanionProject"]) { project = s }
            else if let d = obj["cloudaicompanionProject"] as? [String: Any] { project = JSON.string(d["id"]) ?? JSON.string(d["projectId"]) }
        }
        var body = Data("{}".utf8)
        if let project, let b = CredentialJSON.serialize(["project": project]) { body = b }
        let data = try await get(http, HTTPRequest(url: Self.quotaURL, method: "POST", headers: auth, body: body))
        return try Self.parseQuota(data)
    }

    static func parseQuota(_ data: Data) throws -> [QuotaWindow] {
        guard let root = CredentialJSON.parse(data) else { throw QuotaError.badResponse }
        // Lowest remaining fraction wins per tier, as in CodexBar.
        var tiers: [String: (used: Double, reset: Date?)] = [:]
        for b in (root["buckets"] as? [[String: Any]]) ?? [] {
            guard let model = JSON.string(b["modelId"])?.lowercased(), let remaining = JSON.double(b["remainingFraction"]) else { continue }
            let tier = model.contains("flash-lite") || model.contains("flash_lite") ? "Flash Lite"
                : model.contains("flash") ? "Flash" : model.contains("pro") ? "Pro" : nil
            guard let tier else { continue }
            let used = min(100, max(0, (1 - remaining) * 100))
            let reset = (b["resetTime"] as? String).flatMap(ISO8601.parse)
            if let old = tiers[tier], old.used >= used { continue }
            tiers[tier] = (used, reset)
        }
        return ["Pro", "Flash", "Flash Lite"].compactMap { name in
            tiers[name].map { QuotaWindow(label: name, usedPercent: $0.used, windowMinutes: nil, resetsAt: $0.reset) }
        }
    }
}

/// Finds the Gemini CLI's OAuth client id/secret the way CodexBar does: environment override,
/// then the installed CLI package. Literal patterns are used so minified bundles work too.
public enum GeminiOAuthClientLocator {
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                              home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> (id: String, secret: String)? {
        if let id = environment["GEMINI_OAUTH_CLIENT_ID"], let s = environment["GEMINI_OAUTH_CLIENT_SECRET"], !id.isEmpty, !s.isEmpty {
            return (id, s)
        }
        var files: [URL] = []
        if let p = environment["GEMINI_OAUTH2_JS_PATH"] { files.append(URL(fileURLWithPath: p)) }
        let roots = ["/opt/homebrew/lib/node_modules", "/usr/local/lib/node_modules",
                     "/opt/homebrew/opt/gemini-cli/libexec/lib/node_modules", "/usr/local/opt/gemini-cli/libexec/lib/node_modules",
                     home.appendingPathComponent(".npm-global/lib/node_modules").path,
                     home.appendingPathComponent(".bun/install/global/node_modules").path]
        for r in roots {
            let pkg = URL(fileURLWithPath: r).appendingPathComponent("@google/gemini-cli")
            files.append(pkg.appendingPathComponent("node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js"))
            files.append(URL(fileURLWithPath: r).appendingPathComponent("@google/gemini-cli-core/dist/src/code_assist/oauth2.js"))
            let bundle = pkg.appendingPathComponent("bundle")
            if let items = try? FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil) {
                files.append(contentsOf: items.filter { $0.pathExtension == "js" }.prefix(60))
            }
        }
        for f in files {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: f.path),
                  (attrs[.size] as? NSNumber)?.intValue ?? Int.max < 20_000_000,
                  let text = try? String(contentsOf: f, encoding: .utf8), let found = extract(from: text) else { continue }
            return found
        }
        return nil
    }

    static func extract(from text: String) -> (id: String, secret: String)? {
        func first(_ pattern: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r = Range(m.range, in: text) else { return nil }
            return String(text[r])
        }
        guard let id = first("[0-9]+-[a-z0-9]+\\.apps\\.googleusercontent\\.com"),
              let secret = first("GOCSPX-[A-Za-z0-9_-]+") else { return nil }
        return (id, secret)
    }
}
