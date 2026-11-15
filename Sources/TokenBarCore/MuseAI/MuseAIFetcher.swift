import Foundation

/// Reads the muse.ai weekly allowance through the settings dialog's Next.js server action
/// `fetchSubscriptionAction`, using the signed-in session's cookies.
///
/// Ported from CodexBar `Sources/CodexBarCore/Resources/Plugins/museai.js` (see docs/museai.md):
/// - request: `POST https://muse.ai/` with `Next-Action: <id>`, `Accept: text/x-component`,
///   `Content-Type: text/plain;charset=UTF-8`, same-origin `Sec-Fetch-*` headers and the JSON body
///   `[{"includeAgreement":true}]`;
/// - signed out: HTTP 401/403 or a redirect to `https://auth.muse.ai/`;
/// - stale action id (after a deploy): HTTP 400, 404 or 409 -> one rediscovery from the JS chunks;
/// - response: React Server Components rows `<hex>:{json}`; the subscription is the row with `"success":true`.
public struct MuseAIFetcher: Sendable {
    public struct Limits: Sendable {
        /// Page chunks inspected while looking for the settings loader (CodexBar: 96).
        public var maxPageChunks = 96
        /// Settings chunks inspected for the action id (CodexBar: 32).
        public var maxSettingsChunks = 32
        /// Chunks fetched concurrently (CodexBar: 8).
        public var batchSize = 8
        /// A single chunk larger than this is ignored.
        public var maxChunkBytes = 4 << 20
        /// Total chunk text before discovery gives up (CodexBar: 8 MiB).
        public var maxTotalChunkBytes = 8 << 20
        /// Per-request timeout (CodexBar's default request deadline is 15 s).
        public var requestTimeout: TimeInterval = 15
        /// Whole rediscovery budget; exceeding it is reported as `.network`.
        public var discoveryBudget: TimeInterval = 90
        public init() {}
    }

    public static let origin = "https://muse.ai"
    static let rootURL = URL(string: "https://muse.ai/")!
    static let authPrefix = "https://auth.muse.ai/"
    public static let actionIDKey = "museai.fetchSubscriptionActionID"
    /// CodexBar sends a desktop Chrome user agent (museai.js line 11).
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
    static let actionBody = Data(#"[{"includeAgreement":true}]"#.utf8)

    private let http: HTTPClient
    private let store: MuseAIKeyValueStore
    private let limits: Limits
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - http: use `MuseAIHTTPClient()` in the app (it exposes redirects; see its documentation).
    ///   - actionIDStore: remembers the last working action id across launches.
    public init(http: HTTPClient = MuseAIHTTPClient(),
                actionIDStore: MuseAIKeyValueStore = MuseAIUserDefaultsStore(),
                limits: Limits = Limits(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.http = http
        self.store = actionIDStore
        self.limits = limits
        self.now = now
    }

    // MARK: - Public entry points

    /// Fetches usage with a stored cookie set; an expired set fails locally without a request.
    public func fetch(cookies: MuseAICookieSet) async -> Result<MuseAIUsage, MuseAIFailure> {
        let t = now()
        guard !cookies.isExpired(at: t), let header = cookies.cookieHeader(at: t) else {
            return .failure(.sessionExpired)
        }
        return await fetch(cookieHeader: header)
    }

    /// Fetches usage with a raw `Cookie` header value.
    public func fetch(cookieHeader: String) async -> Result<MuseAIUsage, MuseAIFailure> {
        guard !cookieHeader.isEmpty else { return .failure(.signedOut) }
        do {
            return .success(try await subscription(cookie: cookieHeader))
        } catch let f as MuseAIFailure {
            return .failure(f)
        } catch {
            return .failure(.network)
        }
    }

    /// One `GET https://muse.ai/`: 200 means signed in, a redirect to auth.muse.ai or 401/403 means
    /// signed out (the same test CodexBar's discovery applies to the page, museai.js line 58).
    public func checkSession(cookieHeader: String) async -> MuseAISessionCheck {
        guard !cookieHeader.isEmpty else { return .signedOut }
        guard let r = try? await http.send(pageRequest(cookie: cookieHeader)) else { return .unknown }
        if Self.signedOut(r) { return .signedOut }
        return r.status == 200 ? .signedIn : .unknown
    }

    // MARK: - Flow (museai.js lines 82-125)

    private func subscription(cookie: String) async throws -> MuseAIUsage {
        if let cached = store.string(forKey: Self.actionIDKey), !cached.isEmpty {
            let r = try await post(cookie: cookie, actionID: cached)
            if !Self.needsRediscovery(r) {
                if Self.signedOut(r) { throw MuseAIFailure.sessionExpired }
                // Transient errors and parse failures keep the cached id (CodexBar only drops it before rediscovery).
                return try parse(r)
            }
        }
        // At most one rediscovery per fetch.
        store.setString(nil, forKey: Self.actionIDKey)
        guard let fresh = try await discover(cookie: cookie) else { throw MuseAIFailure.sessionExpired }
        let r = try await post(cookie: cookie, actionID: fresh)
        if Self.needsRediscovery(r) { throw MuseAIFailure.siteChanged }
        if Self.signedOut(r) { throw MuseAIFailure.sessionExpired }
        let usage = try parse(r)
        store.setString(fresh, forKey: Self.actionIDKey)
        return usage
    }

    private func parse(_ r: HTTPResponse) throws -> MuseAIUsage {
        guard r.status == 200 else { throw MuseAIFailure.server(r.status) }
        guard let usage = MuseAIResponseParser.parse(r.body, observedAt: now()) else { throw MuseAIFailure.siteChanged }
        return usage
    }

    static func signedOut(_ r: HTTPResponse) -> Bool {
        if r.status == 401 || r.status == 403 { return true }
        if (300..<400).contains(r.status) {
            // MuseAIHTTPClient puts the Location value in the body of an unfollowed redirect.
            let location = String(decoding: r.body.prefix(2048), as: UTF8.self)
            return location.hasPrefix(authPrefix)
        }
        return false
    }

    /// "A redeployed muse.ai answers a stale action with 400, 404 or 409" (museai.js lines 16-17).
    static func needsRediscovery(_ r: HTTPResponse) -> Bool {
        !signedOut(r) && [400, 404, 409].contains(r.status)
    }

    private func post(cookie: String, actionID: String) async throws -> HTTPResponse {
        let req = HTTPRequest(url: Self.rootURL, method: "POST", headers: [
            "Cookie": cookie,
            "Accept": "text/x-component",
            "Next-Action": actionID,
            "Origin": Self.origin,
            // muse.ai answers 403 to server actions that do not look like same-origin browser fetches.
            "Sec-Fetch-Site": "same-origin",
            "Sec-Fetch-Mode": "cors",
            "Sec-Fetch-Dest": "empty",
            "Content-Type": "text/plain;charset=UTF-8",
            "User-Agent": Self.userAgent,
        ], body: Self.actionBody, timeout: limits.requestTimeout)
        do { return try await http.send(req) } catch { throw MuseAIFailure.network }
    }

    private func pageRequest(cookie: String) -> HTTPRequest {
        HTTPRequest(url: Self.rootURL, headers: ["Cookie": cookie, "Accept": "text/html", "User-Agent": Self.userAgent],
                    timeout: limits.requestTimeout)
    }

    // MARK: - Action id discovery (museai.js lines 38-80)

    /// Returns nil when muse.ai treats the session as signed out.
    private func discover(cookie: String) async throws -> String? {
        let started = now()
        let page: HTTPResponse
        do { page = try await http.send(pageRequest(cookie: cookie)) } catch { throw MuseAIFailure.network }
        if Self.signedOut(page) { return nil }
        guard page.status == 200 else { throw MuseAIFailure.server(page.status) }

        let paths = Array(MuseAIDiscovery.chunkPaths(in: String(decoding: page.body, as: UTF8.self))
            .prefix(limits.maxPageChunks))
        var text = ""
        var i = 0
        while i < paths.count {
            try checkBudget(started)
            let batch = Array(paths[i..<min(paths.count, i + limits.batchSize)])
            i += limits.batchSize
            for body in await fetchChunks(batch) { text += "\n"; text += body }
            if text.utf8.count > limits.maxTotalChunkBytes { throw MuseAIFailure.siteChanged }
            guard let loader = MuseAIDiscovery.settingsLoaderList(in: text) else { continue }
            let settingsPaths = Array(MuseAIDiscovery.chunkPaths(in: loader).prefix(limits.maxSettingsChunks))
            var j = 0
            while j < settingsPaths.count {
                try checkBudget(started)
                let sb = Array(settingsPaths[j..<min(settingsPaths.count, j + limits.batchSize)])
                j += limits.batchSize
                for body in await fetchChunks(sb) {
                    if let id = MuseAIDiscovery.actionID(in: body) { return id }
                }
            }
            break
        }
        throw MuseAIFailure.siteChanged
    }

    private func checkBudget(_ started: Date) throws {
        if now().timeIntervalSince(started) > limits.discoveryBudget { throw MuseAIFailure.network }
    }

    /// Static chunks are fetched without cookies; failures and non-200 answers become "".
    private func fetchChunks(_ paths: [String]) async -> [String] {
        let http = self.http
        let timeout = limits.requestTimeout
        let maxBytes = limits.maxChunkBytes
        return await withTaskGroup(of: (Int, String).self) { group in
            for (index, path) in paths.enumerated() {
                guard let url = URL(string: Self.origin + path) else { continue }
                group.addTask {
                    let req = HTTPRequest(url: url, headers: ["Accept": "*/*", "User-Agent": Self.userAgent], timeout: timeout)
                    guard let r = try? await http.send(req), r.status == 200, r.body.count <= maxBytes else { return (index, "") }
                    return (index, String(decoding: r.body, as: UTF8.self))
                }
            }
            var out = Array(repeating: "", count: paths.count)
            for await (index, body) in group { out[index] = body }
            return out
        }
    }
}

/// Text patterns used to rediscover the action id. Each mirrors a regular expression in museai.js.
enum MuseAIDiscovery {
    /// `static/chunks/<name>.js` mapped to `/_next/<match>`, de-duplicated in order (museai.js line 39).
    /// muse.ai now also serves `static/immutable/chunks/<name>.js` (seen November 2026), so one optional
    /// directory between `static/` and `chunks/` is accepted.
    static func chunkPaths(in text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for m in MuseAIRegex.matches(#"static/(?:[a-z]+/)?chunks/[A-Za-z0-9_~.\-]+\.js"#, in: text) {
            let p = "/_next/" + m
            if seen.insert(p).inserted { out.append(p) }
        }
        return out
    }

    /// The app chunk preloads settings via `e.A(<module>).then(({preloadHatchSettingsData…`; the loader
    /// chunk lists that module's files: `,<module>,s=>{s.v(t=>Promise.all([<files>]` (lines 66-68).
    /// Returns the bracketed file list, or nil when not (yet) found.
    static func settingsLoaderList(in text: String) -> String? {
        guard let module = MuseAIRegex.firstGroup(#"\.A\((\d+)\)\.then\(\(\{[^}]*Settings"#, in: text) else { return nil }
        return MuseAIRegex.firstGroup(#"[,{\[]"# + module + #",[A-Za-z0-9_]+=>\{[A-Za-z0-9_]+\.v\([A-Za-z0-9_]+=>Promise\.all\(\[([^\]]*)"#, in: text)
    }

    /// `createServerReference("<id>", …, "fetchSubscriptionAction")` (line 73).
    static func actionID(in text: String) -> String? {
        MuseAIRegex.firstGroup(#""([0-9a-f]{40,})",[^"]{0,200}"fetchSubscriptionAction""#, in: text)
    }
}

/// Parses the React Server Components (flight) response of the action (museai.js lines 115-152).
public enum MuseAIResponseParser {
    public static func parse(_ body: Data, observedAt: Date) -> MuseAIUsage? {
        var sub: [String: MuseAIJSON]?
        // Split on any line break ("\r\n" is a single Character, so split(separator: "\n") would miss it).
        for line in String(decoding: body, as: UTF8.self).components(separatedBy: .newlines) where !line.isEmpty {
            guard let json = MuseAIRegex.firstGroup(#"^[0-9a-f]+:(\{.*\})\s*$"#, in: line),
                  let row = try? JSONDecoder().decode(MuseAIJSON.self, from: Data(json.utf8)),
                  case .object(let obj) = row, obj["success"] == .bool(true) else { continue }
            // Last matching row wins, as in the source.
            if case .object(let s)? = obj["subscription"] { sub = s } else { sub = nil }
        }
        guard let sub, case .object(let usage)? = sub["usage"], let percent = usage["percentUsed"]?.number else { return nil }

        let resetsAt = usage["resetsAt"]?.number.map { Date(timeIntervalSince1970: $0) }
        let window = QuotaWindow(label: "Weekly", usedPercent: min(100, max(0, percent)), windowMinutes: 7 * 24 * 60,
                                 resetsAt: resetsAt)
        var plan: String?
        if case .object(let tier)? = sub["tier"] { plan = tier["name"]?.string }
        plan = plan ?? sub["usageRowLabel"]?.string

        var topUp: MuseAITopUp?
        if let balance = sub["topupBalance"]?.number, let total = sub["topupTotal"]?.number, total > 0 {
            let valueLabel = sub["topupRowValueLabel"]?.string
            // Balance is in micro-dollars; used only when muse.ai gives no label.
            let value = tokensLeft(valueLabel) ?? valueLabel ?? String(format: "$%.2f left", balance / 1e6)
            topUp = MuseAITopUp(label: sub["topupRowLabel"]?.string ?? "Additional tokens", value: value,
                                usedFraction: min(1, max(0, (total - balance) / total)))
        }
        var renews: Date?
        if case .object(let agreement)? = sub["agreement"] {
            renews = agreement["currentPeriodEndTime"]?.number.map { Date(timeIntervalSince1970: $0) }
        }
        return MuseAIUsage(planName: plan, windows: [window], tokensLeft: tokensLeft(sub["usageRowValueLabel"]?.string),
                           topUp: topUp, renewsAt: renews, observedAt: observedAt)
    }

    /// "3% used (2.8B tokens left)" -> "2.8B tokens left" (line 127).
    static func tokensLeft(_ label: String?) -> String? {
        guard let label else { return nil }
        return MuseAIRegex.firstGroup(#"\(([^()]+ tokens left)\)"#, in: label)
    }
}

/// Minimal JSON value with JavaScript-like typing (a number is never a bool and vice versa).
enum MuseAIJSON: Decodable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([MuseAIJSON]), object([String: MuseAIJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([MuseAIJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: MuseAIJSON].self)) }
    }

    var number: Double? { if case .number(let d) = self, d.isFinite { return d }; return nil }
    /// Non-empty string (JavaScript `??` falls through only on null/undefined, but an empty label is useless).
    var string: String? { if case .string(let s) = self, !s.isEmpty { return s }; return nil }
}

/// NSRegularExpression helpers (Foundation-only, works on Linux).
enum MuseAIRegex {
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var compiled: [String: NSRegularExpression] = [:]
    }
    private static let cache = Cache()

    private static func compile(_ pattern: String) -> NSRegularExpression? {
        cache.lock.lock(); defer { cache.lock.unlock() }
        if let r = cache.compiled[pattern] { return r }
        guard let r = try? NSRegularExpression(pattern: pattern) else { return nil }
        if cache.compiled.count > 64 { cache.compiled.removeAll() }
        cache.compiled[pattern] = r
        return r
    }

    static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let re = compile(pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1,
              m.range(at: 1).location != NSNotFound else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = compile(pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }
}
