import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One stored muse.ai cookie. `description`, `debugDescription` and reflection never show the value.
public struct MuseAICookie: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var name: String
    public var value: String
    /// Lowercased, without a leading dot.
    public var domain: String
    /// True for a host-only cookie (sent only to exactly `domain`).
    public var hostOnly: Bool
    public var path: String
    public var secure: Bool
    /// nil for a browser-session cookie.
    public var expires: Date?

    public init(name: String, value: String, domain: String, hostOnly: Bool = true, path: String = "/",
                secure: Bool = true, expires: Date? = nil) {
        self.name = name
        self.value = value
        let d = domain.lowercased()
        self.domain = d.hasPrefix(".") ? String(d.dropFirst()) : d
        self.hostOnly = hostOnly && !d.hasPrefix(".")
        self.path = path.isEmpty ? "/" : path
        self.secure = secure
        self.expires = expires
    }

    /// Same mapping CodexBar uses for `HTTPCookie` (ProviderPluginCookieRecord.init(cookie:)):
    /// a leading dot means a domain cookie, otherwise host-only.
    public init(_ cookie: HTTPCookie) {
        self.init(name: cookie.name, value: cookie.value, domain: cookie.domain,
                  hostOnly: !cookie.domain.hasPrefix("."), path: cookie.path,
                  secure: cookie.isSecure, expires: cookie.expiresDate)
    }

    /// Whether a browser would send this cookie to `url` at `now`.
    public func matches(_ url: URL, at now: Date) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if let e = expires, e <= now { return false }
        if secure && url.scheme?.lowercased() != "https" { return false }
        guard host == domain || (!hostOnly && host.hasSuffix("." + domain)) else { return false }
        let requestPath = url.path.isEmpty ? "/" : url.path
        guard requestPath.hasPrefix(path) else { return false }
        return requestPath.count == path.count || path.hasSuffix("/") || requestPath.dropFirst(path.count).first == "/"
    }

    public var description: String { "MuseAICookie(\(name), domain: \(domain), value: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["name": name, "domain": domain, "value": "<redacted>"], displayStyle: .struct)
    }
}

/// The cookies TokenBar keeps for one muse.ai account.
///
/// CodexBar declares `cookieDomains: ["muse.ai"]` and sends whatever the browser holds for
/// `https://muse.ai/` (museai.js lines 7, 23-26, 55-56). It does not name a single session
/// cookie, so we keep every cookie that would be sent to `https://muse.ai/` and nothing else
/// (auth.muse.ai, facebook.com, instagram.com, meta.com cookies are dropped).
public struct MuseAICookieSet: Equatable, Sendable, CustomStringConvertible {
    public static let siteURL = URL(string: "https://muse.ai/")!
    /// Name used for the session cookie in CodexBar's test fixtures (`hatch_sess=fixture`).
    /// Not confirmed against the live site, so it is only a hint: it speeds up sign-in
    /// detection and lets a known expiry be detected locally. Nothing depends on it.
    public static let sessionCookieNameHint = "hatch_sess"

    public private(set) var cookies: [MuseAICookie]

    /// Keeps only cookies relevant to `https://muse.ai/` (ignoring expiry, which is checked at use).
    public init(cookies: [MuseAICookie]) {
        let far = Date.distantPast
        self.cookies = cookies.filter { c in
            var probe = c
            probe.expires = nil
            return probe.matches(Self.siteURL, at: far)
        }
    }

    public init(httpCookies: [HTTPCookie]) {
        self.init(cookies: httpCookies.map(MuseAICookie.init))
    }

    public var isEmpty: Bool { cookies.isEmpty }

    public var containsSessionHint: Bool { cookies.contains { $0.name == Self.sessionCookieNameHint } }

    /// `Cookie` header value for `url` at `now` (longest path first, like browsers), or nil if none apply.
    public func cookieHeader(for url: URL = MuseAICookieSet.siteURL, at now: Date) -> String? {
        let live = cookies.filter { $0.matches(url, at: now) }
            .sorted { $0.path.count != $1.path.count ? $0.path.count > $1.path.count : $0.name < $1.name }
        return live.isEmpty ? nil : live.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// True when the session is known to be unusable without asking the server:
    /// no cookie would be sent any more, or the hinted session cookie has expired.
    public func isExpired(at now: Date) -> Bool {
        if cookieHeader(at: now) == nil { return true }
        if let hint = cookies.first(where: { $0.name == Self.sessionCookieNameHint }), let e = hint.expires, e <= now {
            return true
        }
        return false
    }

    /// Earliest expiry among cookies that have one (informational).
    public var earliestExpiry: Date? { cookies.compactMap(\.expires).min() }

    // MARK: - Keychain string

    private struct Stored: Codable {
        var version: Int
        var cookies: [StoredCookie]
    }

    private struct StoredCookie: Codable {
        var name: String
        var value: String
        var domain: String
        var hostOnly: Bool
        var path: String
        var secure: Bool
        /// Unix seconds.
        var expires: Double?
    }

    /// Compact JSON for `SecretStore.setSecret`. Contains cookie values: store it only in the Keychain.
    public func serialized() -> String {
        let stored = Stored(version: 1, cookies: cookies.map {
            StoredCookie(name: $0.name, value: $0.value, domain: $0.domain, hostOnly: $0.hostOnly, path: $0.path,
                         secure: $0.secure, expires: $0.expires?.timeIntervalSince1970)
        })
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(stored), let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    /// Parses `serialized()` output. Returns nil for anything else or for an empty set.
    public init?(serialized: String) {
        guard let data = serialized.data(using: .utf8),
              let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.version == 1 else { return nil }
        self.init(cookies: stored.cookies.map {
            MuseAICookie(name: $0.name, value: $0.value, domain: $0.domain, hostOnly: $0.hostOnly, path: $0.path,
                         secure: $0.secure, expires: $0.expires.map { Date(timeIntervalSince1970: $0) })
        })
        if cookies.isEmpty { return nil }
    }

    public var description: String {
        "MuseAICookieSet(\(cookies.count) cookies: \(cookies.map(\.name).sorted().joined(separator: ", ")))"
    }
}
