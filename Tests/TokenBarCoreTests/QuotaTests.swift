import XCTest
@testable import TokenBarCore

// MARK: - Fakes

final class FakeHTTP: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [HTTPRequest] = []
    var handler: @Sendable (HTTPRequest) throws -> HTTPResponse

    init(_ handler: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse) { self.handler = handler }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.lock(); requests.append(request); lock.unlock()
        return try handler(request)
    }

    func count(host: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.url.host == host }.count
    }
    var total: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
}

final class MemoryStore: CredentialBlobStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data
    var writable = true
    private(set) var writes = 0
    /// Runs before every read; lets a test simulate the CLI changing the store.
    var onRead: (@Sendable (MemoryStore) -> Void)?
    let label = "memory"

    init(_ data: Data) { self.data = data }
    func read() throws -> Data {
        onRead?(self)
        lock.lock(); defer { lock.unlock() }
        return data
    }
    func write(_ d: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard writable else { throw CredentialStoreError.notWritable }
        data = d; writes += 1
    }
    func checkWritable() throws { if !writable { throw CredentialStoreError.notWritable } }
    func replace(_ d: Data) { lock.lock(); data = d; lock.unlock() }
    var current: Data { lock.lock(); defer { lock.unlock() }; return data }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Date
    init(_ t: Date = TestSupport.now) { self.t = t }
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
}

/// Routes any backend's credentials to the test's in-memory store.
struct Routed: QuotaBackend {
    let inner: any QuotaBackend
    var providerID: String { inner.providerID }
    var cliName: String { inner.cliName }
    var refreshPolicy: RefreshPolicy { inner.refreshPolicy }
    func credentialSources(forDataPath dataPath: String, home: URL) -> [CredentialSource] { [.keychain(service: "test")] }
    func parseCredentials(_ raw: Data) -> OAuthCredentials? { inner.parseCredentials(raw) }
    func refreshRequest(for c: OAuthCredentials) -> HTTPRequest? { inner.refreshRequest(for: c) }
    func applyRefresh(response: Data, to raw: Data, now: Date) -> Data? { inner.applyRefresh(response: response, to: raw, now: now) }
    func fetchQuota(credentials: OAuthCredentials, http: HTTPClient, now: Date) async throws -> [QuotaWindow] {
        try await inner.fetchQuota(credentials: credentials, http: http, now: now)
    }
}

func ms(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }

func json(_ s: String) -> Data { Data(s.utf8) }

final class QuotaTests: XCTestCase {
    let t0 = TestSupport.now

    // Claude fixtures ------------------------------------------------------

    func claudeCreds(access: String, refresh: String, expires: Date) -> Data {
        json("""
        {"claudeAiOauth":{"accessToken":"\(access)","refreshToken":"\(refresh)","expiresAt":\(ms(expires)),
        "scopes":["user:inference","user:profile"],"subscriptionType":"max","rateLimitTier":"tier-x"},
        "mcpOAuth":{"server":{"keep":"me"}},"organizationUuid":"org-1"}
        """)
    }

    static let usageBody = json("""
    {"five_hour":{"utilization":23.0,"resets_at":"2025-10-15T15:00:00.000000+00:00"},
     "seven_day":{"utilization":41.5,"resets_at":"2025-10-20T00:00:00Z"},
     "seven_day_opus":null,"seven_day_sonnet":{"utilization":10,"resets_at":null}}
    """)

    static let refreshBody = json("{\"access_token\":\"AT-new\",\"refresh_token\":\"RT-new\",\"expires_in\":28800,\"token_type\":\"Bearer\"}")

    func makeService(backend: any QuotaBackend, store: MemoryStore, http: FakeHTTP, clock: Clock) -> QuotaService {
        QuotaService(backends: [Routed(inner: backend)], http: http, home: URL(fileURLWithPath: "/nonexistent"),
                     keychain: { _ in store }, now: { clock.now })
    }

    let account = Account(providerID: "claude", name: "a", dataPath: "/x")

    func claudeHTTP(onUsage: @escaping @Sendable (HTTPRequest) -> HTTPResponse = { _ in HTTPResponse(status: 200, body: QuotaTests.usageBody) },
                    onRefresh: @escaping @Sendable (HTTPRequest) -> HTTPResponse = { _ in HTTPResponse(status: 200, body: QuotaTests.refreshBody) }) -> FakeHTTP {
        FakeHTTP { req in req.url.host == "api.anthropic.com" ? onUsage(req) : onRefresh(req) }
    }

    // MARK: Claude

    func testValidTokenFetchesQuotaWithoutRefresh() async {
        let store = MemoryStore(claudeCreds(access: "AT-old", refresh: "RT-old", expires: t0.addingTimeInterval(3600)))
        let http = claudeHTTP()
        let svc = makeService(backend: ClaudeQuotaBackend(), store: store, http: http, clock: Clock())
        let r = await svc.refresh(accounts: [account], enabled: true)[account.id]!
        XCTAssertNil(r.issue)
        let w = r.observation!.windows
        XCTAssertEqual(w.map(\.label), ["5 小时", "每周", "Sonnet 每周"])
        XCTAssertEqual(w[0].usedPercent, 23.0)
        XCTAssertEqual(w[0].resetsAt, ISO8601.parse("2025-10-15T15:00:00Z"))
        XCTAssertEqual(w[1].usedPercent, 41.5)
        XCTAssertEqual(http.count(host: "platform.claude.com"), 0)
        XCTAssertEqual(store.writes, 0)
        let req = http.requests[0]
        XCTAssertEqual(req.headers["Authorization"], "Bearer AT-old")
        XCTAssertEqual(req.headers["anthropic-beta"], "oauth-2025-04-20")
    }

    func testExpiredTokenIsRefreshedAndWrittenBackPreservingUnknownFields() async throws {
        let store = MemoryStore(claudeCreds(access: "AT-old", refresh: "RT-old", expires: t0.addingTimeInterval(-10)))
        let http = claudeHTTP()
        let svc = makeService(backend: ClaudeQuotaBackend(), store: store, http: http, clock: Clock())
        let r = await svc.refresh(accounts: [account], enabled: true)[account.id]!
        XCTAssertNil(r.issue)
        XCTAssertEqual(http.count(host: "platform.claude.com"), 1)
        XCTAssertEqual(store.writes, 1)

        // The usage call used the new access token.
        XCTAssertEqual(http.requests.last?.headers["Authorization"], "Bearer AT-new")
        // Refresh request is a form post carrying the old refresh token.
        let body = String(data: http.requests[0].body ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
        XCTAssertTrue(body.contains("refresh_token=RT-old"))

        // Written store: rotated tokens + new expiry, everything else untouched.
        let root = try XCTUnwrap(CredentialJSON.parse(store.current))
        let oauth = try XCTUnwrap(root["claudeAiOauth"] as? [String: Any])
        XCTAssertEqual(oauth["accessToken"] as? String, "AT-new")
        XCTAssertEqual(oauth["refreshToken"] as? String, "RT-new")
        XCTAssertEqual(JSON.int64(oauth["expiresAt"]), ms(t0.addingTimeInterval(28800)))
        XCTAssertEqual(oauth["subscriptionType"] as? String, "max")
        XCTAssertEqual(oauth["rateLimitTier"] as? String, "tier-x")
        XCTAssertEqual((oauth["scopes"] as? [String])?.count, 2)
        XCTAssertEqual(root["organizationUuid"] as? String, "org-1")
        XCTAssertNotNil((root["mcpOAuth"] as? [String: Any])?["server"])
    }

    func test401TriggersExactlyOneRefreshAndOneRetry() async {
        let store = MemoryStore(claudeCreds(access: "AT-old", refresh: "RT-old", expires: t0.addingTimeInterval(3600)))
        let http = claudeHTTP(onUsage: { req in
            req.headers["Authorization"] == "Bearer AT-new" ? HTTPResponse(status: 200, body: QuotaTests.usageBody) : HTTPResponse(status: 401)
        })
        let svc = makeService(backend: ClaudeQuotaBackend(), store: store, http: http, clock: Clock())
        let r = await svc.refresh(accounts: [account], enabled: true)[account.id]!
        XCTAssertNil(r.issue)
        XCTAssertNotNil(r.observation)
        XCTAssertEqual(http.count(host: "platform.claude.com"), 1)
        XCTAssertEqual(http.count(host: "api.anthropic.com"), 2)
    }

    func testPersistent401DoesNotLoop() async {
        let store = MemoryStore(claudeCreds(access: "AT-old", refresh: "RT-old", expires: t0.addingTimeInterval(3600)))
        let http = claudeHTTP(onUsage: { _ in HTTPResponse(status: 401) })
        let clock = Clock()
        let svc = makeService(backend: ClaudeQuotaBackend(), store: store, http: http, clock: clock)
        let r = await svc.refresh(accounts: [account], enabled: true)[account.id]!
        XCTAssertEqual(r.issue, .loginExpired(cli: "claude"))
        XCTAssertEqual(http.count(host: "platform.claude.com"), 1)
        XCTAssertEqual(http.count(host: "api.anthropic.com"), 2)
        // Later refreshes (even forced, even much later) stay blocked while the credentials are unchanged.
        clock.advance(600)
        _ = await svc.refresh(accounts: [account], enabled: true, force: true)
        XCTAssertEqual(http.total, 3)
    }

    func testCLIRefreshedMeanwhileIsAdoptedWithoutSpendingRefreshToken() async {
        let store = MemoryStore(claudeCreds(access: "AT-old", refresh: "RT-old", expires: t0.addingTimeInterval(-10)))
        let http = claudeHTTP()
        // First read (initial load) sees the stale file; by the re-read the CLI has refreshed.
        let reads = Counter()
        store.onRead = { s in
            if reads.bump() == 2 {
                s.replace(self.claudeCreds(access: "AT-cli", refresh: "RT-cli", expires: self.t0.addingTimeInterval(7200)))
            }
        }
        let svc = makeService(backend: ClaudeQuotaBackend(), store: store, http: http, clock: Clock())
        let r = await svc.refresh(accounts: [account], enabled: true)[account.id]!
        XCTAssertNil(r.issue)
        XCTAssertEqual(http.count(host: "platform.claude.com"), 0, "must not refresh when the CLI already did")
        XCTAssertEqual(http.requests.last?.headers["Authorization"], "Bearer AT-cli")
        XCTAssertEqual(store.writes, 0)
    }

    func testStoreChangedDuringRefreshIsNotOverwritten() async throws {
        let store = MemoryStore(claudeCreds(access: "AT-old", refresh: "RT-old", expires: t0.addingTimeInterval(-10)))
        let http = claudeHTTP(onRefresh: { _ in
            // CLI wins the race while our request is in flight.
            store.replace(self.claudeCreds(access: "AT-cli", refresh: "RT-cli", expires: self.t0.addingTimeInterval(7200)))
            return HTTPResponse(status: 200, body: QuotaTests.refreshBody)
        })
        let svc = makeService(backend: ClaudeQuotaBackend(), store: store, http: http, clock: Clock())
        let r = await svc.refresh(accounts: [account], enabled: true)[account.id]!
        XCTAssertNil(r.issue)
        XCTAssertEqual(store.writes, 0)
        let root = try XCTUnwrap(CredentialJSON.parse(store.current))
        XCTAssertEqual((root["claudeAiOauth"] as? [String: Any])?["refreshToken"] as? String, "RT-cli")
    }

    func testUnwritableStoreNeverSpendsTheRefreshToken() async {
        let store = MemoryStore(claudeCreds(access: "AT-old", refresh: "RT-old", expires: t0.addingTimeInterval(-10)))
        store.writable = false
        let http = claudeHTTP()
        let svc = makeService(backend: ClaudeQuotaBackend(), store: store, http: http, clock: Clock())
        let r = await svc.refresh(accounts: [account], enabled: true)[account.id]!
        XCTAssertEqual(r.issue, .cannotWriteBack(cli: "claude"))
        XCTAssertEqual(http.total, 0)
    }

    func testRefreshRejectedMeansLoginExpiredAndBlocksUntilCredentialsChange() async {
        let store = MemoryStore(claudeCreds(access: "AT-old", refresh: "RT-old", expires: t0.addingTimeInterval(-10)))
        let http = claudeHTTP(onRefresh: { _ in HTTPResponse(status: 400, body: json("{\"error\":\"invalid_grant\"}")) })
        let clock = Clock()
        let svc = makeService(backend: ClaudeQuotaBackend(), store: store, http: http, clock: clock)
        var r = await svc.refresh(accounts: [account], enabled: true)[account.id]!
        XCTAssertEqual(r.issue, .loginExpired(cli: "claude"))
        XCTAssertEqual(http.total, 1)

        clock.advance(400)
        _ = await svc.refresh(accounts: [account], enabled: true)
        XCTAssertEqual(http.total, 1, "blocked: no new network call")

        // The user logs in again: the block lifts as soon as the stored credentials change.
        store.replace(claudeCreds(access: "AT-login", refresh: "RT-login", expires: clock.now.addingTimeInterval(3600)))
        r = await svc.refresh(accounts: [account], enabled: true, force: true)[account.id]!
        XCTAssertNil(r.issue)
        XCTAssertNotNil(r.observation)
    }

    func testNetworkFailureBacksOffExponentiallyAndKeepsLastGoodQuota() async {
        let store = MemoryStore(claudeCreds(access: "AT-old", refresh: "RT-old", expires: t0.addingTimeInterval(86400)))
        let failing = Flag()
        let http = FakeHTTP { _ in
            if failing.value { throw URLError(.notConnectedToInternet) }
            return HTTPResponse(status: 200, body: QuotaTests.usageBody)
        }
        let clock = Clock()
        let svc = makeService(backend: ClaudeQuotaBackend(), store: store, http: http, clock: clock)

        var r = await svc.refresh(accounts: [account], enabled: true)[account.id]!
        XCTAssertNotNil(r.observation)
        XCTAssertEqual(http.total, 1)

        // Within minInterval nothing is fetched, whatever the UI refresh rate.
        clock.advance(60)
        _ = await svc.refresh(accounts: [account], enabled: true)
        XCTAssertEqual(http.total, 1)

        failing.value = true
        clock.advance(300)
        r = await svc.refresh(accounts: [account], enabled: true)[account.id]!
        XCTAssertEqual(http.total, 2)
        XCTAssertEqual(r.issue, .network)
        XCTAssertNotNil(r.observation, "local-looking data must survive a failed refresh")

        clock.advance(301)           // first backoff is 300s -> allowed again
        _ = await svc.refresh(accounts: [account], enabled: true)
        XCTAssertEqual(http.total, 3)
        clock.advance(301)           // second backoff doubled to 600s -> still blocked
        _ = await svc.refresh(accounts: [account], enabled: true)
        XCTAssertEqual(http.total, 3)
        clock.advance(400)
        _ = await svc.refresh(accounts: [account], enabled: true)
        XCTAssertEqual(http.total, 4)

        failing.value = false
        clock.advance(4000)
        r = await svc.refresh(accounts: [account], enabled: true)[account.id]!
        XCTAssertNil(r.issue)
    }

    func testDisabledAndUnsupportedNeverTouchTheNetwork() async {
        let store = MemoryStore(claudeCreds(access: "AT", refresh: "RT", expires: t0.addingTimeInterval(3600)))
        let http = claudeHTTP()
        let svc = makeService(backend: ClaudeQuotaBackend(), store: store, http: http, clock: Clock())
        var off = account
        off.onlineQuotaEnabled = false
        let muse = Account(providerID: "muse", name: "m", dataPath: "/m")
        let globalOff = await svc.refresh(accounts: [account], enabled: false)
        XCTAssertEqual(globalOff[account.id]?.issue, .disabled)
        let r = await svc.refresh(accounts: [off, muse], enabled: true)
        XCTAssertEqual(r[off.id]?.issue, .disabled)
        XCTAssertEqual(r[muse.id]?.issue, .unsupported)
        XCTAssertEqual(http.total, 0)
    }

    func testMissingCredentials() async {
        let store = MemoryStore(json("{}"))
        let svc = makeService(backend: ClaudeQuotaBackend(), store: store, http: claudeHTTP(), clock: Clock())
        let r = await svc.refresh(accounts: [account], enabled: true)[account.id]!
        XCTAssertEqual(r.issue, .notSignedIn)
    }

    func testIssueMessagesNeverContainTokens() {
        let issues: [QuotaIssue] = [.loginExpired(cli: "claude"), .cannotWriteBack(cli: "gemini"), .network, .server(500), .accessDenied, .other]
        for i in issues { XCTAssertFalse(i.message.contains("AT-")) }
        XCTAssertEqual(QuotaIssue.loginExpired(cli: "codex").message, "登录已过期，运行一次 codex 即可恢复")
    }

    // MARK: Codex (CLI owns the refresh chain)

    func jwt(exp: Date) -> String {
        func b64(_ s: String) -> String {
            Data(s.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        }
        return "\(b64("{\"alg\":\"none\"}")).\(b64("{\"exp\":\(Int(exp.timeIntervalSince1970))}")).sig"
    }

    func codexAuth(exp: Date) -> Data {
        json("{\"OPENAI_API_KEY\":null,\"tokens\":{\"id_token\":\"idt\",\"access_token\":\"\(jwt(exp: exp))\",\"refresh_token\":\"RT-codex\",\"account_id\":\"acct-1\"},\"last_refresh\":\"2025-10-15T10:00:00Z\"}")
    }

    static let wham = json("""
    {"plan_type":"plus","rate_limit":{"allowed":true,"limit_reached":false,
     "primary_window":{"used_percent":17,"limit_window_seconds":18000,"reset_after_seconds":3000,"reset_at":1760540000},
     "secondary_window":{"used_percent":62,"limit_window_seconds":604800,"reset_after_seconds":90000,"reset_at":1761000000}}}
    """)

    func testCodexFetchUsesAccountHeaderAndParsesWindows() async {
        let store = MemoryStore(codexAuth(exp: t0.addingTimeInterval(3600)))
        let http = FakeHTTP { _ in HTTPResponse(status: 200, body: QuotaTests.wham) }
        let a = Account(providerID: "codex", name: "c", dataPath: "/c")
        let svc = makeService(backend: CodexQuotaBackend(), store: store, http: http, clock: Clock())
        let r = await svc.refresh(accounts: [a], enabled: true)[a.id]!
        XCTAssertNil(r.issue)
        XCTAssertEqual(r.observation?.windows.map(\.label), ["5 小时", "每周"])
        XCTAssertEqual(r.observation?.windows[0].usedPercent, 17)
        XCTAssertEqual(r.observation?.windows[1].resetsAt, Date(timeIntervalSince1970: 1_761_000_000))
        XCTAssertEqual(http.requests[0].headers["ChatGPT-Account-Id"], "acct-1")
        XCTAssertEqual(http.requests[0].url.path, "/backend-api/wham/usage")
    }

    func testCodexExpiredLoginIsNeverRefreshedByTokenBar() async {
        let store = MemoryStore(codexAuth(exp: t0.addingTimeInterval(-3600)))
        let http = FakeHTTP { _ in HTTPResponse(status: 200, body: QuotaTests.wham) }
        let a = Account(providerID: "codex", name: "c", dataPath: "/c")
        let svc = makeService(backend: CodexQuotaBackend(), store: store, http: http, clock: Clock())
        let r = await svc.refresh(accounts: [a], enabled: true)[a.id]!
        XCTAssertEqual(r.issue, .loginExpired(cli: "codex"))
        XCTAssertEqual(http.total, 0)
        XCTAssertEqual(store.writes, 0)
    }

    func testCodexAdoptsCLIRenewal() async {
        let store = MemoryStore(codexAuth(exp: t0.addingTimeInterval(-3600)))
        let reads = Counter()
        let fresh = codexAuth(exp: t0.addingTimeInterval(7200)).replacing("acct-1", with: "acct-1")
        store.onRead = { s in if reads.bump() == 2 { s.replace(fresh) } }
        let http = FakeHTTP { _ in HTTPResponse(status: 200, body: QuotaTests.wham) }
        let a = Account(providerID: "codex", name: "c", dataPath: "/c")
        let svc = makeService(backend: CodexQuotaBackend(), store: store, http: http, clock: Clock())
        let r = await svc.refresh(accounts: [a], enabled: true)[a.id]!
        XCTAssertNil(r.issue)
        XCTAssertEqual(http.total, 1)
    }

    // MARK: Gemini

    func geminiCreds(expires: Date) -> Data {
        json("{\"access_token\":\"G-old\",\"refresh_token\":\"G-rt\",\"scope\":\"x\",\"token_type\":\"Bearer\",\"id_token\":\"idt-old\",\"expiry_date\":\(ms(expires)),\"custom\":{\"a\":1}}")
    }

    func testGeminiRefreshWritesOnlyTokenFieldsAndMapsBuckets() async throws {
        let store = MemoryStore(geminiCreds(expires: t0.addingTimeInterval(-5)))
        let http = FakeHTTP { req in
            switch req.url.host {
            case "oauth2.googleapis.com":
                return HTTPResponse(status: 200, body: json("{\"access_token\":\"G-new\",\"expires_in\":3599,\"id_token\":\"idt-new\",\"token_type\":\"Bearer\"}"))
            default:
                if req.url.absoluteString.hasSuffix(":loadCodeAssist") {
                    return HTTPResponse(status: 200, body: json("{\"cloudaicompanionProject\":\"proj-1\",\"currentTier\":{\"id\":\"free-tier\"}}"))
                }
                return HTTPResponse(status: 200, body: json("""
                {"buckets":[{"modelId":"gemini-2.5-pro","remainingFraction":0.75,"resetTime":"2025-10-16T00:00:00Z","tokenType":"REQUESTS"},
                {"modelId":"gemini-2.5-flash","remainingFraction":0.9,"resetTime":"2025-10-16T00:00:00Z"},
                {"modelId":"gemini-2.5-flash","remainingFraction":0.4,"resetTime":"2025-10-16T00:00:00Z"},
                {"modelId":"gemini-2.5-flash-lite","remainingFraction":1.0}]}
                """))
            }
        }
        let backend = GeminiQuotaBackend(clientLocator: { ("client-id", "client-secret") })
        let a = Account(providerID: "gemini", name: "g", dataPath: "/g")
        let svc = makeService(backend: backend, store: store, http: http, clock: Clock())
        let r = await svc.refresh(accounts: [a], enabled: true)[a.id]!
        XCTAssertNil(r.issue)
        let w = try XCTUnwrap(r.observation?.windows)
        XCTAssertEqual(w.map(\.label), ["Pro", "Flash", "Flash Lite"])
        XCTAssertEqual(w[0].usedPercent, 25, accuracy: 0.001)
        XCTAssertEqual(w[1].usedPercent, 60, accuracy: 0.001, "lowest remaining fraction wins")
        XCTAssertEqual(w[2].usedPercent, 0, accuracy: 0.001)

        let quotaReq = try XCTUnwrap(http.requests.last)
        XCTAssertEqual(String(data: quotaReq.body ?? Data(), encoding: .utf8).map { $0.contains("proj-1") }, true)
        XCTAssertEqual(quotaReq.headers["Authorization"], "Bearer G-new")

        let root = try XCTUnwrap(CredentialJSON.parse(store.current))
        XCTAssertEqual(root["access_token"] as? String, "G-new")
        XCTAssertEqual(root["id_token"] as? String, "idt-new")
        XCTAssertEqual(root["refresh_token"] as? String, "G-rt")
        XCTAssertEqual(JSON.int64(root["expiry_date"]), ms(t0.addingTimeInterval(3599)))
        XCTAssertEqual(root["scope"] as? String, "x")
        XCTAssertNotNil(root["custom"])
    }

    func testGeminiWithoutInstalledClientCannotRefresh() async {
        let store = MemoryStore(geminiCreds(expires: t0.addingTimeInterval(-5)))
        let http = FakeHTTP { _ in HTTPResponse(status: 200) }
        let a = Account(providerID: "gemini", name: "g", dataPath: "/g")
        let svc = makeService(backend: GeminiQuotaBackend(clientLocator: { nil }), store: store, http: http, clock: Clock())
        let r = await svc.refresh(accounts: [a], enabled: true)[a.id]!
        XCTAssertEqual(r.issue, .loginExpired(cli: "gemini"))
        XCTAssertEqual(http.total, 0)
    }

    func testGeminiClientExtractionFromBundleText() {
        let js = "const a='681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com',b=\"GOCSPX-abcDEF_123-xyz\";"
        let r = GeminiOAuthClientLocator.extract(from: js)
        XCTAssertEqual(r?.id, "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com")
        XCTAssertEqual(r?.secret, "GOCSPX-abcDEF_123-xyz")
        XCTAssertNil(GeminiOAuthClientLocator.extract(from: "nothing here"))
    }

    // MARK: File store

    func testFileBlobStoreAtomicWritePreservesPermissionsAndSymlinks() throws {
        let dir = try TestSupport.tempDir()
        let real = dir.appendingPathComponent("real.json")
        try Data("{\"a\":1}".utf8).write(to: real)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)
        let link = dir.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let store = FileBlobStore(url: link)
        try store.checkWritable()
        try store.write(Data("{\"a\":2}".utf8))

        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "{\"a\":2}")
        let attrs = try FileManager.default.attributesOfItem(atPath: real.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), "symlink must survive")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty)
        XCTAssertThrowsError(try FileBlobStore(url: dir.appendingPathComponent("missing.json")).read())
    }

    func testBackendCredentialSources() {
        let home = URL(fileURLWithPath: "/Users/me")
        XCTAssertEqual(ClaudeQuotaBackend().credentialSources(forDataPath: "/Users/me/.claude", home: home),
                       [.file(URL(fileURLWithPath: "/Users/me/.claude/.credentials.json")), .keychain(service: "Claude Code-credentials")])
        XCTAssertEqual(ClaudeQuotaBackend().credentialSources(forDataPath: "/Users/me/claude-work", home: home),
                       [.file(URL(fileURLWithPath: "/Users/me/claude-work/.credentials.json")),
                        .keychain(service: "Claude Code-credentials-cbe7f9b7"),
                        .keychain(service: "Claude Code-credentials-11876416")])
        XCTAssertEqual(CodexQuotaBackend().credentialSources(forDataPath: "/Users/me/.codex", home: home),
                       [.file(URL(fileURLWithPath: "/Users/me/.codex/auth.json"))])
        XCTAssertEqual(GeminiQuotaBackend().credentialSources(forDataPath: "/Users/me/.gemini", home: home),
                       [.file(URL(fileURLWithPath: "/Users/me/.gemini/oauth_creds.json"))])
    }

    func testDailyBucketsOnFixture() async throws {
        let dir = try TestSupport.copyFixture("claude")
        let u = await TestSupport.usage(provider: "claude", path: dir)
        XCTAssertEqual(u.daily.count, 7)
        XCTAssertEqual(u.daily.last?.day, ISO8601.parse("2025-10-15T00:00:00Z"))
        XCTAssertEqual(u.daily.first?.day, ISO8601.parse("2025-10-09T00:00:00Z"))
        XCTAssertEqual(u.daily[6].tokens, u.today)
        XCTAssertEqual(u.daily[2].tokens, TokenBreakdown(input: 10, output: 20, cacheRead: 500, cacheWrite: 0))  // Oct 11
        XCTAssertEqual(u.daily.reduce(TokenBreakdown.zero) { $0 + $1.tokens }, u.last7Days)
    }

    func testAccountDecodesWithoutNewField() throws {
        let id = UUID()
        let data = json("{\"id\":\"\(id.uuidString)\",\"providerID\":\"claude\",\"name\":\"n\",\"dataPath\":\"/p\"}")
        let a = try JSONDecoder().decode(Account.self, from: data)
        XCTAssertTrue(a.onlineQuotaEnabled)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}

private extension Data {
    func replacing(_ a: String, with b: String) -> Data {
        Data((String(data: self, encoding: .utf8) ?? "").replacingOccurrences(of: a, with: b).utf8)
    }
}

final class QuotaMergeTests: XCTestCase {
    func testPathValidationPerProvider() throws {
        let claude = ClaudeProvider()
        let good = try TestSupport.copyFixture("claude")
        XCTAssertEqual(claude.validate(dataPath: good.path), .valid)
        XCTAssertEqual(claude.validate(dataPath: good.path + "/nope"), .missing)
        XCTAssertEqual(claude.validate(dataPath: good.appendingPathComponent("projects/-Users-me-proj/sess-1.jsonl").path), .notADirectory)
        let empty = try TestSupport.tempDir()
        XCTAssertEqual(claude.validate(dataPath: empty.path), .noLogsFound(expected: ["projects/"]))
        XCTAssertEqual(MuseProvider().validate(dataPath: try TestSupport.copyFixture("muse").path), .valid)
        XCTAssertEqual(MuseProvider().validate(dataPath: empty.path), .noLogsFound(expected: ["session.jsonl"]))
        XCTAssertEqual(CodexProvider().validate(dataPath: empty.path), .noLogsFound(expected: ["sessions/", "archived_sessions/"]))
        XCTAssertEqual(GeminiProvider().validate(dataPath: try TestSupport.copyFixture("gemini").path), .valid)
    }

    func testEffectiveQuotaPrefersOnlineAndPeakIgnoresStaleWindows() {
        let now = TestSupport.now
        let a = Account(providerID: "codex", name: "a", dataPath: "")
        let local = QuotaObservation(observedAt: now, windows: [QuotaWindow(label: "5 小时", usedPercent: 95, resetsAt: now.addingTimeInterval(-5))])
        let online = QuotaObservation(observedAt: now, windows: [QuotaWindow(label: "5 小时", usedPercent: 30, resetsAt: now.addingTimeInterval(500)),
                                                                 QuotaWindow(label: "每周", usedPercent: 91, resetsAt: nil)])
        let usage = [a.id: AccountUsage(quota: local, updatedAt: now)]
        XCTAssertEqual(QuotaMerge.effective(local: local, online: nil)?.isOnline, false)
        XCTAssertEqual(QuotaMerge.effective(local: local, online: online)?.isOnline, true)
        XCTAssertNil(QuotaMerge.effective(local: nil, online: nil))
        XCTAssertEqual(QuotaMerge.peakPercent(accounts: [a], usage: usage, quota: [a.id: QuotaResult(observation: online)], now: now), 91)
        // Local-only with an already reset window: no warning.
        XCTAssertEqual(QuotaMerge.peakPercent(accounts: [a], usage: usage, quota: [:], now: now), nil)
    }

    func testWriteBackKeepsSingleLineLayout() throws {
        let compact = Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1,"scopes":["x"]},"other":true}"#.utf8)
        let resp = Data(#"{"access_token":"n","refresh_token":"r2","expires_in":3600}"#.utf8)
        let out = try XCTUnwrap(ClaudeQuotaBackend().applyRefresh(response: resp, to: compact, now: Date()))
        XCTAssertFalse(out.contains(0x0A))
        XCTAssertEqual(ClaudeQuotaBackend().parseCredentials(out)?.refreshToken, "r2")
        let pretty = Data("{\n  \"access_token\": \"a\",\n  \"refresh_token\": \"r\"\n}\n".utf8)
        let g = try XCTUnwrap(GeminiQuotaBackend().applyRefresh(response: resp, to: pretty, now: Date()))
        XCTAssertTrue(g.contains(0x0A))
    }

    func testSHA256KnownVectors() {
        XCTAssertEqual(SHA256Lite.hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256Lite.hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256Lite.hex(String(repeating: "a", count: 119)).count, 64)
    }
}
