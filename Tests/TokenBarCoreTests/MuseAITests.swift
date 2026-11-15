import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import TokenBarCore

// Fixtures under Fixtures/museai are hand-written from the shapes in CodexBar's museai.js and
// MuseAIPluginTests.swift; they were not captured from the live site.

private enum MuseFixtures {
    static func text(_ name: String) -> String {
        let url = TestSupport.fixtures.appendingPathComponent("museai").appendingPathComponent(name)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
    static let actionID = "40447f7d32b58c622904d92f8ac01a13f4798568bd"
    static let staleID = "40aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    static let secretValue = "S3CR3T-session-value-do-not-leak"
    static var cookieHeader: String { "hatch_sess=\(secretValue)" }
}

/// Scripted muse.ai. Logs "METHOD path [action]" for every request.
private final class MuseFakeSite: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _log: [String] = []
    private var _requests: [HTTPRequest] = []
    var chunks: [String: String] = [
        "/_next/static/chunks/app.js": MuseFixtures.text("app.js"),
        "/_next/static/chunks/loader.js": MuseFixtures.text("loader.js"),
        "/_next/static/chunks/settings.js": MuseFixtures.text("settings.js"),
        "/_next/static/chunks/other.js": "nothing here",
    ]
    var page = MuseFixtures.text("page.html")
    var pageStatus = 200
    var pageLocation = ""
    /// Response for the current (valid) action id.
    var action = MuseFixtures.text("action-maximum.txt")
    var actionStatus = 200
    var actionLocation = ""
    /// Status for any other action id.
    var staleStatus = 404
    /// Ids the server accepts as current.
    var validIDs: Set<String> = [MuseFixtures.actionID]
    var transportError = false
    /// Called before each request (e.g. to move a clock).
    var onRequest: (@Sendable (HTTPRequest) -> Void)?
    /// Awaited before answering (to hold a request open).
    var hold: (@Sendable () async -> Void)?

    var log: [String] { lock.lock(); defer { lock.unlock() }; return _log }
    var requests: [HTTPRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    var posts: Int { log.filter { $0.hasPrefix("POST") }.count }

    private func record(_ request: HTTPRequest, line: String) {
        lock.lock(); defer { lock.unlock() }
        _log.append(line)
        _requests.append(request)
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        onRequest?(request)
        if let hold { await hold() }
        let path = request.url.path
        let action = request.headers["Next-Action"]
        record(request, line: [request.method, path, action].compactMap { $0 }.joined(separator: " "))
        if transportError { throw URLError(.notConnectedToInternet) }
        if request.method == "POST" {
            guard let action, validIDs.contains(action) else { return HTTPResponse(status: staleStatus, body: Data("Action unavailable.".utf8)) }
            if (300..<400).contains(actionStatus) { return HTTPResponse(status: actionStatus, body: Data(actionLocation.utf8)) }
            return HTTPResponse(status: actionStatus, body: Data(self.action.utf8))
        }
        if path == "/" {
            if (300..<400).contains(pageStatus) { return HTTPResponse(status: pageStatus, body: Data(pageLocation.utf8)) }
            return HTTPResponse(status: pageStatus, body: Data(page.utf8))
        }
        if let body = chunks[path] { return HTTPResponse(status: 200, body: Data(body.utf8)) }
        return HTTPResponse(status: 404)
    }
}

private final class MuseClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Date
    init(_ t: Date = TestSupport.now) { self.t = t }
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
}

final class MuseAIFetcherTests: XCTestCase {
    private func fetcher(_ site: MuseFakeSite, store: MuseAIKeyValueStore, clock: MuseClock = MuseClock(),
                         limits: MuseAIFetcher.Limits = .init()) -> MuseAIFetcher {
        MuseAIFetcher(http: site, actionIDStore: store, limits: limits, now: { clock.now })
    }

    private func cached(_ id: String? = MuseFixtures.actionID) -> MuseAIMemoryKeyValueStore {
        MuseAIMemoryKeyValueStore(id.map { [MuseAIFetcher.actionIDKey: $0] } ?? [:])
    }

    func testPaidPlanHappyPath() async throws {
        let site = MuseFakeSite()
        let usage = try await fetcher(site, store: cached()).fetch(cookieHeader: MuseFixtures.cookieHeader).get()
        XCTAssertEqual(site.log, ["POST / \(MuseFixtures.actionID)"])
        XCTAssertEqual(usage.planName, "Maximum")
        XCTAssertEqual(usage.windows, [QuotaWindow(label: "Weekly", usedPercent: 3, windowMinutes: 10080,
                                                   resetsAt: Date(timeIntervalSince1970: 1_790_634_838))])
        XCTAssertEqual(usage.tokensLeft, "2.8B tokens left")
        XCTAssertEqual(usage.topUp, MuseAITopUp(label: "Additional tokens", value: "1.5B tokens left", usedFraction: 0.25))
        XCTAssertEqual(usage.renewsAt, Date(timeIntervalSince1970: 1_790_721_238))
        XCTAssertEqual(usage.quotaObservation.windows.count, 1)

        let req = try XCTUnwrap(site.requests.first)
        XCTAssertEqual(req.url.absoluteString, "https://muse.ai/")
        XCTAssertEqual(req.headers["Cookie"], MuseFixtures.cookieHeader)
        XCTAssertEqual(req.headers["Accept"], "text/x-component")
        XCTAssertEqual(req.headers["Content-Type"], "text/plain;charset=UTF-8")
        XCTAssertEqual(req.headers["Origin"], "https://muse.ai")
        XCTAssertEqual(req.headers["Sec-Fetch-Site"], "same-origin")
        XCTAssertEqual(req.headers["Sec-Fetch-Mode"], "cors")
        XCTAssertEqual(req.headers["Sec-Fetch-Dest"], "empty")
        XCTAssertEqual(req.body.map { String(decoding: $0, as: UTF8.self) }, #"[{"includeAgreement":true}]"#)
    }

    func testFreePlanAndUnlabeledTopUp() async throws {
        let site = MuseFakeSite()
        site.action = MuseFixtures.text("action-free.txt")
        let free = try await fetcher(site, store: cached()).fetch(cookieHeader: MuseFixtures.cookieHeader).get()
        XCTAssertEqual(free.planName, "Muse Free")
        XCTAssertEqual(free.windows.first?.usedPercent, 28)
        XCTAssertNil(free.tokensLeft)
        XCTAssertNil(free.topUp)
        XCTAssertNil(free.renewsAt)

        site.action = MuseFixtures.text("action-maximum.txt")
            .replacingOccurrences(of: #""topupRowValueLabel":"25% used (1.5B tokens left)""#, with: #""topupRowValueLabel":null"#)
            .replacingOccurrences(of: #""topupBalance":60000000"#, with: #""topupBalance":80000000"#)
        let paid = try await fetcher(site, store: cached()).fetch(cookieHeader: MuseFixtures.cookieHeader).get()
        XCTAssertEqual(paid.topUp?.value, "$80.00 left")
        XCTAssertEqual(paid.topUp?.usedFraction, 0)
    }

    /// muse.ai serves its scripts from `static/immutable/chunks/` (seen November 2026) as well as the older
    /// `static/chunks/`; both are found, in order and without duplicates, and nothing else is.
    func testChunkPathsAcceptImmutableDirectory() {
        let html = #"<script src="/_next/static/immutable/chunks/04d5giu9rtvpf.js"></script>"#
            + #"<script src="/_next/static/chunks/main-app.js"></script>"#
            + #"<script src="/_next/static/immutable/chunks/04d5giu9rtvpf.js"></script>"#
            + #"<link href="/_next/static/css/app.css"><script src="/_next/static/a/b/chunks/x.js"></script>"#
        XCTAssertEqual(MuseAIDiscovery.chunkPaths(in: html),
                       ["/_next/static/immutable/chunks/04d5giu9rtvpf.js", "/_next/static/chunks/main-app.js"])
        // The settings loader lists files without the /_next/ prefix.
        XCTAssertEqual(MuseAIDiscovery.chunkPaths(in: #""static/immutable/chunks/0l3dsgtys_rhp.js""#),
                       ["/_next/static/immutable/chunks/0l3dsgtys_rhp.js"])
    }

    func testDiscoveryWithoutCachedIDStoresID() async throws {
        let site = MuseFakeSite()
        let store = cached(nil)
        let usage = try await fetcher(site, store: store).fetch(cookieHeader: MuseFixtures.cookieHeader).get()
        XCTAssertEqual(usage.planName, "Maximum")
        XCTAssertEqual(store.string(forKey: MuseAIFetcher.actionIDKey), MuseFixtures.actionID)
        XCTAssertEqual(site.log.first, "GET /")
        XCTAssertEqual(site.log.last, "POST / \(MuseFixtures.actionID)")
        XCTAssertTrue(site.log.contains("GET /_next/static/chunks/settings.js"))
        XCTAssertFalse(site.log.contains("GET /_next/static/chunks/other.js"))
        XCTAssertEqual(site.log.filter { $0 == "GET /_next/static/chunks/app.js" }.count, 1, "chunk paths are de-duplicated")
        // Static chunks never get cookies; the page does.
        for r in site.requests where r.url.path.hasPrefix("/_next/") { XCTAssertNil(r.headers["Cookie"]) }
        XCTAssertEqual(site.requests.first?.headers["Cookie"], MuseFixtures.cookieHeader)
    }

    func testStaleIDIsRediscoveredOnce() async throws {
        for status in [400, 404, 409] {
            let site = MuseFakeSite()
            site.staleStatus = status
            let store = cached(MuseFixtures.staleID)
            let usage = try await fetcher(site, store: store).fetch(cookieHeader: MuseFixtures.cookieHeader).get()
            XCTAssertEqual(usage.windows.first?.usedPercent, 3)
            XCTAssertEqual(site.posts, 2, "status \(status)")
            XCTAssertEqual(site.log.first, "POST / \(MuseFixtures.staleID)")
            XCTAssertEqual(store.string(forKey: MuseAIFetcher.actionIDKey), MuseFixtures.actionID)
        }
    }

    func testRediscoveryIsBoundedToOneAttempt() async {
        let site = MuseFakeSite()
        site.validIDs = []   // even the rediscovered id is rejected as stale
        let store = cached(MuseFixtures.staleID)
        let result = await fetcher(site, store: store).fetch(cookieHeader: MuseFixtures.cookieHeader)
        XCTAssertEqual(result.failure, .siteChanged)
        XCTAssertEqual(site.posts, 2)
        XCTAssertEqual(site.log.filter { $0 == "GET /" }.count, 1)
        XCTAssertNil(store.string(forKey: MuseAIFetcher.actionIDKey), "an unusable id is never cached")
    }

    func testDiscoveryCapsPageChunks() async {
        let site = MuseFakeSite()
        site.page = (0..<120).map { "<script src=\"/_next/static/chunks/chunk\($0).js\"></script>" }.joined()
        let result = await fetcher(site, store: cached(nil)).fetch(cookieHeader: MuseFixtures.cookieHeader)
        XCTAssertEqual(result.failure, .siteChanged)
        XCTAssertEqual(site.log.filter { $0.hasPrefix("GET /_next/") }.count, 96)
        XCTAssertEqual(site.posts, 0)
    }

    func testDiscoveryCapsSettingsChunks() async {
        let site = MuseFakeSite()
        let paths = (0..<60).map { "\"static/chunks/settings\($0).js\"" }.joined(separator: ",")
        site.chunks["/_next/static/chunks/loader.js"] = "},434304,s=>{s.v(t=>Promise.all([\(paths)].map(t=>s.l(t))))}"
        let result = await fetcher(site, store: cached(nil)).fetch(cookieHeader: MuseFixtures.cookieHeader)
        XCTAssertEqual(result.failure, .siteChanged)
        XCTAssertEqual(site.log.filter { $0.hasPrefix("GET /_next/static/chunks/settings") }.count, 32)
    }

    func testDiscoveryCapsChunkSizes() async {
        let site = MuseFakeSite()
        var limits = MuseAIFetcher.Limits()
        limits.maxTotalChunkBytes = 1000
        site.chunks["/_next/static/chunks/app.js"] = String(repeating: "x", count: 2000)
        let tooMuch = await fetcher(site, store: cached(nil), limits: limits).fetch(cookieHeader: MuseFixtures.cookieHeader)
        XCTAssertEqual(tooMuch.failure, .siteChanged)

        // A single oversized chunk is ignored, so the settings module is never found.
        let site2 = MuseFakeSite()
        var limits2 = MuseAIFetcher.Limits()
        limits2.maxChunkBytes = 20
        let ignored = await fetcher(site2, store: cached(nil), limits: limits2).fetch(cookieHeader: MuseFixtures.cookieHeader)
        XCTAssertEqual(ignored.failure, .siteChanged)
        XCTAssertEqual(site2.posts, 0)
    }

    func testDiscoveryTimeBudget() async {
        let site = MuseFakeSite()
        let clock = MuseClock()
        site.onRequest = { _ in clock.advance(60) }
        var limits = MuseAIFetcher.Limits()
        limits.discoveryBudget = 90
        let result = await fetcher(site, store: cached(nil), clock: clock, limits: limits).fetch(cookieHeader: MuseFixtures.cookieHeader)
        XCTAssertEqual(result.failure, .network)
        XCTAssertEqual(site.posts, 0)
    }

    func testTransientStatusKeepsCachedIDWithoutRediscovery() async {
        for status in [408, 429, 500, 502] {
            let site = MuseFakeSite()
            site.actionStatus = status
            site.action = ""
            let store = cached()
            let result = await fetcher(site, store: store).fetch(cookieHeader: MuseFixtures.cookieHeader)
            XCTAssertEqual(result.failure, .server(status))
            XCTAssertEqual(site.log, ["POST / \(MuseFixtures.actionID)"])
            XCTAssertEqual(store.string(forKey: MuseAIFetcher.actionIDKey), MuseFixtures.actionID)
        }
    }

    func testSignedOutAnswersMeanSessionExpired() async {
        // Forbidden action.
        let site = MuseFakeSite()
        site.actionStatus = 403
        var r = await fetcher(site, store: cached()).fetch(cookieHeader: MuseFixtures.cookieHeader)
        XCTAssertEqual(r.failure, .sessionExpired)
        XCTAssertEqual(site.posts, 1)

        // 401 on the action.
        let site401 = MuseFakeSite()
        site401.actionStatus = 401
        r = await fetcher(site401, store: cached()).fetch(cookieHeader: MuseFixtures.cookieHeader)
        XCTAssertEqual(r.failure, .sessionExpired)

        // Action redirected to the sign-in host.
        let redirected = MuseFakeSite()
        redirected.actionStatus = 307
        redirected.actionLocation = "https://auth.muse.ai/aymh/?origin=https%3A%2F%2Fmuse.ai"
        r = await fetcher(redirected, store: cached()).fetch(cookieHeader: MuseFixtures.cookieHeader)
        XCTAssertEqual(r.failure, .sessionExpired)

        // Discovery page redirected to the sign-in host (CodexBar test case 307/200).
        let page = MuseFakeSite()
        page.pageStatus = 307
        page.pageLocation = "https://auth.muse.ai/aymh/?origin=https%3A%2F%2Fmuse.ai"
        r = await fetcher(page, store: cached(nil)).fetch(cookieHeader: MuseFixtures.cookieHeader)
        XCTAssertEqual(r.failure, .sessionExpired)
        XCTAssertEqual(page.posts, 0)

        // A redirect elsewhere is just an unexpected status.
        let other = MuseFakeSite()
        other.actionStatus = 302
        other.actionLocation = "https://muse.ai/maintenance"
        r = await fetcher(other, store: cached()).fetch(cookieHeader: MuseFixtures.cookieHeader)
        XCTAssertEqual(r.failure, .server(302))

        // Empty cookie header: nothing to send.
        let none = MuseFakeSite()
        r = await fetcher(none, store: cached()).fetch(cookieHeader: "")
        XCTAssertEqual(r.failure, .signedOut)
        XCTAssertEqual(none.log, [])
    }

    func testNetworkFailure() async {
        let site = MuseFakeSite()
        site.transportError = true
        let store = cached()
        let r = await fetcher(site, store: store).fetch(cookieHeader: MuseFixtures.cookieHeader)
        XCTAssertEqual(r.failure, .network)
        XCTAssertEqual(store.string(forKey: MuseAIFetcher.actionIDKey), MuseFixtures.actionID)
    }

    func testUnexpectedResponseIsSiteChangedAndNeverCached() async {
        for body in ["1:{\"success\":false}", "<!DOCTYPE html><html></html>", "1:{\"success\":true,\"subscription\":{\"usage\":{\"percentUsed\":\"3\"}}}",
                     "1:{\"success\":1,\"subscription\":{\"usage\":{\"percentUsed\":3}}}"] {
            let site = MuseFakeSite()
            site.action = body
            let store = cached(nil)
            let r = await fetcher(site, store: store).fetch(cookieHeader: MuseFixtures.cookieHeader)
            XCTAssertEqual(r.failure, .siteChanged, body)
            XCTAssertNil(store.string(forKey: MuseAIFetcher.actionIDKey))
        }
    }

    func testDiscoveryPageServerError() async {
        let site = MuseFakeSite()
        site.pageStatus = 503
        let r = await fetcher(site, store: cached(nil)).fetch(cookieHeader: MuseFixtures.cookieHeader)
        XCTAssertEqual(r.failure, .server(503))
    }

    func testCheckSession() async {
        let ok = MuseFakeSite()
        var check = await fetcher(ok, store: cached()).checkSession(cookieHeader: MuseFixtures.cookieHeader)
        XCTAssertEqual(check, .signedIn)
        let out = MuseFakeSite()
        out.pageStatus = 307
        out.pageLocation = "https://auth.muse.ai/aymh/"
        check = await fetcher(out, store: cached()).checkSession(cookieHeader: MuseFixtures.cookieHeader)
        XCTAssertEqual(check, .signedOut)
        let down = MuseFakeSite()
        down.transportError = true
        check = await fetcher(down, store: cached()).checkSession(cookieHeader: MuseFixtures.cookieHeader)
        XCTAssertEqual(check, .unknown)
    }

    func testParserTakesLastSuccessRowAndClampsPercent() {
        let body = """
        0:{"a":"$@1"}
        1:{"success":true,"subscription":{"tier":{"name":"Power"},"usage":{"percentUsed":5}}}\r
        2:{"success":true,"subscription":{"usageRowLabel":"Plan X","usage":{"percentUsed":140}}}
        """
        let u = MuseAIResponseParser.parse(Data(body.utf8), observedAt: TestSupport.now)
        XCTAssertEqual(u?.planName, "Plan X")
        XCTAssertEqual(u?.windows.first?.usedPercent, 100)
        XCTAssertNil(u?.windows.first?.resetsAt)
    }
}

final class MuseAICookieTests: XCTestCase {
    private let now = TestSupport.now

    private func sample() -> MuseAICookieSet {
        MuseAICookieSet(cookies: [
            MuseAICookie(name: "hatch_sess", value: MuseFixtures.secretValue, domain: "muse.ai",
                         expires: now.addingTimeInterval(86400)),
            MuseAICookie(name: "csrf", value: "abc", domain: ".muse.ai", hostOnly: false),
            MuseAICookie(name: "auth_only", value: "x", domain: "auth.muse.ai"),
            MuseAICookie(name: "fb", value: "x", domain: ".facebook.com", hostOnly: false),
            MuseAICookie(name: "deep", value: "x", domain: "muse.ai", path: "/api"),
        ])
    }

    func testFiltersToCookiesSentToMuseAI() {
        XCTAssertEqual(sample().cookies.map(\.name).sorted(), ["csrf", "hatch_sess"])
    }

    func testHeaderAndRoundTrip() throws {
        let set = sample()
        let s = set.serialized()
        let back = try XCTUnwrap(MuseAICookieSet(serialized: s))
        XCTAssertEqual(back, set)
        XCTAssertEqual(back.cookieHeader(at: now), "csrf=abc; hatch_sess=\(MuseFixtures.secretValue)")
        XCTAssertTrue(back.containsSessionHint)
        XCTAssertFalse(back.isExpired(at: now))
        XCTAssertNil(MuseAICookieSet(serialized: "garbage"))
        XCTAssertNil(MuseAICookieSet(serialized: MuseAICookieSet(cookies: []).serialized()))
    }

    func testHTTPCookieConversion() throws {
        let props: [HTTPCookiePropertyKey: Any] = [
            .name: "hatch_sess", .value: "v", .domain: ".muse.ai", .path: "/", .secure: "TRUE",
            .expires: now.addingTimeInterval(60),
        ]
        let c = try XCTUnwrap(HTTPCookie(properties: props))
        let set = MuseAICookieSet(httpCookies: [c])
        XCTAssertEqual(set.cookies.first?.domain, "muse.ai")
        XCTAssertEqual(set.cookies.first?.hostOnly, false)
        XCTAssertEqual(set.cookieHeader(at: now), "hatch_sess=v")
    }

    func testLocalExpiry() {
        let set = sample()
        // The hinted session cookie expires after a day even though "csrf" is a session cookie.
        XCTAssertTrue(set.isExpired(at: now.addingTimeInterval(86400)))
        let onlyExpiring = MuseAICookieSet(cookies: [MuseAICookie(name: "other", value: "v", domain: "muse.ai",
                                                                  expires: now.addingTimeInterval(10))])
        XCTAssertFalse(onlyExpiring.isExpired(at: now))
        XCTAssertTrue(onlyExpiring.isExpired(at: now.addingTimeInterval(10)))
        XCTAssertNil(onlyExpiring.cookieHeader(at: now.addingTimeInterval(11)))
    }

    func testNoSecretInDescriptions() {
        let set = sample()
        var dumped = ""
        dump(set, to: &dumped)
        let texts = [String(describing: set), String(reflecting: set), "\(set.cookies)", dumped,
                     String(describing: set.cookies[0]), String(reflecting: set.cookies[0])]
            + [MuseAIFailure.signedOut, .sessionExpired, .siteChanged, .network, .server(500)].flatMap {
                [String(describing: $0), $0.message, $0.localizedDescription]
            }
        for t in texts { XCTAssertFalse(t.contains(MuseFixtures.secretValue), t) }
        XCTAssertTrue(String(describing: set).contains("hatch_sess"))
    }
}

final class MuseAIServiceTests: XCTestCase {
    private let account = UUID()

    private func make(_ site: MuseFakeSite, clock: MuseClock, secrets: InMemorySecretStore,
                      store: MuseAIKeyValueStore = MuseAIMemoryKeyValueStore([MuseAIFetcher.actionIDKey: MuseFixtures.actionID]))
        -> MuseAIService {
        let fetcher = MuseAIFetcher(http: site, actionIDStore: store, now: { clock.now })
        return MuseAIService(fetcher: fetcher, secrets: secrets, now: { clock.now })
    }

    private func secret(_ value: String = MuseFixtures.secretValue, expires: Date? = nil) -> String {
        MuseAICookieSet(cookies: [MuseAICookie(name: "hatch_sess", value: value, domain: "muse.ai", expires: expires)]).serialized()
    }

    func testThrottleReusesSuccessAndAllowsManualAfter30s() async throws {
        let site = MuseFakeSite(), clock = MuseClock(), secrets = InMemorySecretStore()
        try secrets.setSecret(secret(), for: account)
        let svc = make(site, clock: clock, secrets: secrets)

        let first = await svc.refresh(accountID: account)
        XCTAssertEqual(first.usage?.planName, "Maximum")
        XCTAssertNil(first.failure)
        XCTAssertEqual(site.posts, 1)
        XCTAssertEqual(site.requests.first?.headers["Cookie"], "hatch_sess=\(MuseFixtures.secretValue)")

        clock.advance(20)
        _ = await svc.refresh(accountID: account, force: true)
        XCTAssertEqual(site.posts, 1, "manual refresh within 30 s reuses the result")
        clock.advance(11)
        _ = await svc.refresh(accountID: account, force: true)
        XCTAssertEqual(site.posts, 2, "manual refresh after 30 s goes out")

        clock.advance(299)
        _ = await svc.refresh(accountID: account)
        XCTAssertEqual(site.posts, 2, "background refresh within 5 min reuses the result")
        clock.advance(1)
        _ = await svc.refresh(accountID: account)
        XCTAssertEqual(site.posts, 3)
    }

    func testExponentialBackoffCappedAtOneHour() async throws {
        let site = MuseFakeSite(), clock = MuseClock(), secrets = InMemorySecretStore()
        site.actionStatus = 500
        try secrets.setSecret(secret(), for: account)
        let svc = make(site, clock: clock, secrets: secrets)

        var expected = 0
        for delay in [300.0, 600, 1200, 2400, 3600, 3600] {
            let s = await svc.refresh(accountID: account)
            expected += 1
            XCTAssertEqual(s.failure, .server(500))
            XCTAssertEqual(site.posts, expected)
            clock.advance(delay - 1)
            _ = await svc.refresh(accountID: account)
            XCTAssertEqual(site.posts, expected, "blocked before \(delay) s")
            clock.advance(1)
        }

        // Success resets the backoff and keeps nothing stale.
        site.actionStatus = 200
        let ok = await svc.refresh(accountID: account)
        XCTAssertNil(ok.failure)
        XCTAssertNotNil(ok.usage)
    }

    func testFailureKeepsLastUsage() async throws {
        let site = MuseFakeSite(), clock = MuseClock(), secrets = InMemorySecretStore()
        try secrets.setSecret(secret(), for: account)
        let svc = make(site, clock: clock, secrets: secrets)
        _ = await svc.refresh(accountID: account)
        site.transportError = true
        clock.advance(300)
        let s = await svc.refresh(accountID: account)
        XCTAssertEqual(s.failure, .network)
        XCTAssertEqual(s.usage?.planName, "Maximum")
    }

    func testSessionExpiredHaltsBackgroundRetriesUntilCookiesChange() async throws {
        let site = MuseFakeSite(), clock = MuseClock(), secrets = InMemorySecretStore()
        site.actionStatus = 403
        try secrets.setSecret(secret(), for: account)
        let svc = make(site, clock: clock, secrets: secrets)

        let s = await svc.refresh(accountID: account)
        XCTAssertEqual(s.failure, .sessionExpired)
        XCTAssertEqual(site.posts, 1)
        for _ in 0..<5 {
            clock.advance(7200)
            _ = await svc.refresh(accountID: account)
        }
        XCTAssertEqual(site.posts, 1, "no background retries with the rejected cookies")

        // A manual refresh may try again (rate limited).
        _ = await svc.refresh(accountID: account, force: true)
        XCTAssertEqual(site.posts, 2)
        _ = await svc.refresh(accountID: account, force: true)
        XCTAssertEqual(site.posts, 2)

        // New cookies (re-sign-in) lift the halt immediately.
        site.actionStatus = 200
        try secrets.setSecret(secret("new-session"), for: account)
        let fresh = await svc.refresh(accountID: account)
        XCTAssertNil(fresh.failure)
        XCTAssertEqual(site.posts, 3)
        XCTAssertEqual(site.requests.last?.headers["Cookie"], "hatch_sess=new-session")
    }

    func testLocallyExpiredCookiesNeedNoRequest() async throws {
        let site = MuseFakeSite(), clock = MuseClock(), secrets = InMemorySecretStore()
        try secrets.setSecret(secret(expires: clock.now.addingTimeInterval(-1)), for: account)
        let svc = make(site, clock: clock, secrets: secrets)
        let s = await svc.refresh(accountID: account, force: true)
        XCTAssertEqual(s.failure, .sessionExpired)
        XCTAssertEqual(site.log, [])
    }

    func testMissingSecretIsSignedOutAndForgetClearsState() async throws {
        let site = MuseFakeSite(), clock = MuseClock(), secrets = InMemorySecretStore()
        let svc = make(site, clock: clock, secrets: secrets)
        let s = await svc.refresh(accountID: account)
        XCTAssertEqual(s.failure, .signedOut)
        XCTAssertEqual(site.log, [])

        try secrets.setSecret(secret(), for: account)
        _ = await svc.refresh(accountID: account)
        let current = await svc.state(for: account)
        XCTAssertNotNil(current?.usage)
        await svc.forget(accountID: account)
        let gone = await svc.state(for: account)
        XCTAssertNil(gone)
    }

    func testAccountsAreIndependent() async throws {
        let site = MuseFakeSite(), clock = MuseClock(), secrets = InMemorySecretStore()
        let other = UUID()
        try secrets.setSecret(secret("a"), for: account)
        try secrets.setSecret(secret("b"), for: other)
        let svc = make(site, clock: clock, secrets: secrets)
        let states = await svc.refresh(accountIDs: [account, other])
        XCTAssertEqual(states.count, 2)
        XCTAssertEqual(site.posts, 2)
        XCTAssertEqual(Set(site.requests.compactMap { $0.headers["Cookie"] }), ["hatch_sess=a", "hatch_sess=b"])
    }

    func testOneRequestInFlightPerAccount() async throws {
        let site = MuseFakeSite(), clock = MuseClock(), secrets = InMemorySecretStore()
        try secrets.setSecret(secret(), for: account)
        let gate = MuseGate()
        site.hold = { await gate.wait() }
        let svc = make(site, clock: clock, secrets: secrets)
        async let first = svc.refresh(accountID: account, force: true)
        // Give the first call time to reach the network.
        try await Task.sleep(nanoseconds: 100_000_000)
        let second = await svc.refresh(accountID: account, force: true)
        XCTAssertNil(second.usage, "concurrent call returns the current state instead of starting another request")
        await gate.open()
        let done = await first
        XCTAssertNotNil(done.usage)
        XCTAssertEqual(site.posts, 1)
    }
}

/// Holds fake requests until opened.
private actor MuseGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private extension Result {
    var failure: Failure? { if case .failure(let f) = self { return f }; return nil }
}
