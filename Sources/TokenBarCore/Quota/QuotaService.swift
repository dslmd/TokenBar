import Foundation

/// Fetches online quota for accounts, renewing expired logins when that is safe.
///
/// Safety rules (the refresh token of these CLIs rotates, so a careless refresh logs the user
/// out of their CLI):
/// - credentials are re-read from the CLI's own store right before any refresh, and a refresh
///   that the CLI already performed is simply adopted;
/// - a refresh only happens if the store has proven writable, and the new tokens are written
///   back atomically with unknown JSON fields preserved; the store is compared once more
///   immediately before writing so a concurrent CLI refresh is never overwritten;
/// - providers whose chain the CLI owns (`delegateToCLI`) are never refreshed here;
/// - at most one request cycle per account in flight, failures back off exponentially,
///   and successful results are cached for `minInterval` whatever the UI refresh rate is.
public actor QuotaService {
    public struct Timing: Sendable {
        public var minInterval: TimeInterval = 300
        public var manualMinInterval: TimeInterval = 30
        public var baseBackoff: TimeInterval = 300
        public var maxBackoff: TimeInterval = 3600
        public init() {}
    }

    private struct State {
        var result = QuotaResult()
        var lastAttempt: Date?
        var failures = 0
        var blockedUntil: Date?
        /// Fingerprint of the credentials when a hard auth failure happened; the block lifts when it changes.
        var blockedFingerprint: Int?
        var inFlight = false
    }

    private let backends: [String: any QuotaBackend]
    private let http: HTTPClient
    private let home: URL
    private let timing: Timing
    private let now: @Sendable () -> Date
    private let keychain: (@Sendable (String) -> CredentialBlobStore?)?
    private var states: [UUID: State] = [:]

    public init(backends: [any QuotaBackend],
                http: HTTPClient = URLSessionHTTPClient(),
                home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                timing: Timing = Timing(),
                keychain: (@Sendable (String) -> CredentialBlobStore?)? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.backends = Dictionary(uniqueKeysWithValues: backends.map { ($0.providerID, $0) })
        self.http = http
        self.home = home
        self.timing = timing
        self.keychain = keychain
        self.now = now
    }

    /// Providers that have an online quota backend (Muse does not).
    public static let supportedProviderIDs: Set<String> = ["claude", "codex", "gemini"]

    public static func standard(keychain: (@Sendable (String) -> CredentialBlobStore?)? = nil) -> QuotaService {
        QuotaService(backends: [ClaudeQuotaBackend(), CodexQuotaBackend(), GeminiQuotaBackend()], keychain: keychain)
    }

    /// Refreshes the given accounts concurrently. `enabled` carries the global switch.
    public func refresh(accounts: [Account], enabled: Bool, force: Bool = false) async -> [UUID: QuotaResult] {
        let live = Set(accounts.map(\.id))
        for id in states.keys where !live.contains(id) { states.removeValue(forKey: id) }

        var out: [UUID: QuotaResult] = [:]
        var work: [Account] = []
        for a in accounts {
            if !enabled || !a.onlineQuotaEnabled {
                states[a.id] = nil
                out[a.id] = QuotaResult(issue: .disabled)
            } else if backends[a.providerID] == nil {
                out[a.id] = QuotaResult(issue: .unsupported)
            } else {
                work.append(a)
            }
        }
        // Sequential on purpose: few accounts, and it keeps the request rate low.
        for a in work { out[a.id] = await fetch(a, force: force) }
        return out
    }

    // MARK: - One account

    private func fetch(_ account: Account, force: Bool) async -> QuotaResult {
        guard let backend = backends[account.providerID] else { return QuotaResult(issue: .unsupported) }
        var st = states[account.id] ?? State()
        if st.inFlight { return st.result }
        let t = now()

        let minGap = force ? timing.manualMinInterval : timing.minInterval
        if let last = st.lastAttempt, t.timeIntervalSince(last) < minGap { return st.result }
        if let until = st.blockedUntil, t < until {
            // A hard auth block is lifted early only when the stored credentials changed (user re-logged in).
            // A denied Keychain prompt is retried only on an explicit manual refresh (never in the background).
            let retryDenied = force && st.result.issue == .accessDenied
            if !retryDenied, st.blockedFingerprint == nil || fingerprint(stores(for: account, backend: backend)) == st.blockedFingerprint {
                return st.result
            }
        }

        st.inFlight = true
        st.lastAttempt = t
        states[account.id] = st
        let outcome = await run(account: account, backend: backend)
        var s = states[account.id] ?? State()
        s.inFlight = false
        switch outcome {
        case .success(let windows):
            s.result = QuotaResult(observation: QuotaObservation(observedAt: now(), windows: windows))
            s.failures = 0
            s.blockedUntil = nil
            s.blockedFingerprint = nil
        case .failure(let issue, let hard):
            s.result = QuotaResult(observation: s.result.observation, issue: issue)
            s.failures += 1
            let delay = hard ? timing.maxBackoff
                : min(timing.maxBackoff, timing.baseBackoff * pow(2, Double(s.failures - 1)))
            s.blockedUntil = now().addingTimeInterval(delay)
            // Never re-read a store that just refused us: that would raise another Keychain prompt.
            s.blockedFingerprint = (hard && issue != .accessDenied) ? fingerprint(stores(for: account, backend: backend)) : nil
        }
        states[account.id] = s
        return s.result
    }

    private enum Outcome {
        case success([QuotaWindow])
        case failure(QuotaIssue, hard: Bool)
    }

    private struct Fail: Error {
        var issue: QuotaIssue
        var hard: Bool
        init(_ issue: QuotaIssue, _ hard: Bool) { self.issue = issue; self.hard = hard }
    }

    private struct Loaded {
        var store: CredentialBlobStore
        var raw: Data
        var credentials: OAuthCredentials
    }

    private func stores(for account: Account, backend: any QuotaBackend) -> [CredentialBlobStore] {
        backend.credentialSources(forDataPath: expandPath(account.dataPath), home: home).compactMap { source in
            switch source {
            case .file(let url): return FileBlobStore(url: url)
            case .keychain(let service): return keychain?(service)
            }
        }
    }

    private func fingerprint(_ stores: [CredentialBlobStore]) -> Int {
        var h = Hasher()
        for s in stores { if let d = try? s.read() { h.combine(d) } }
        return h.finalize()
    }

    /// First store that holds parseable credentials; reports the most informative failure otherwise.
    private func load(_ stores: [CredentialBlobStore], backend: any QuotaBackend) -> Result<Loaded, QuotaIssue> {
        var issue: QuotaIssue = .notSignedIn
        for s in stores {
            do {
                let raw = try s.read()
                if let c = backend.parseCredentials(raw) { return .success(Loaded(store: s, raw: raw, credentials: c)) }
            } catch CredentialStoreError.denied {
                issue = .accessDenied
            } catch {
                continue
            }
        }
        return .failure(issue)
    }

    private func run(account: Account, backend: any QuotaBackend) async -> Outcome {
        let all = stores(for: account, backend: backend)
        var loaded: Loaded
        switch load(all, backend: backend) {
        case .success(let l): loaded = l
        case .failure(let issue): return .failure(issue, hard: issue == .accessDenied)
        }

        var renewed = false
        if loaded.credentials.isExpired(at: now()) {
            switch await renew(loaded, backend: backend) {
            case .success(let l): loaded = l; renewed = true
            case .failure(let f): return .failure(f.issue, hard: f.hard)
            }
        }

        while true {
            do {
                let windows = try await backend.fetchQuota(credentials: loaded.credentials, http: http, now: now())
                return .success(windows)
            } catch QuotaError.unauthorized {
                if renewed { return .failure(.loginExpired(cli: backend.cliName), hard: true) }
                switch await renew(loaded, backend: backend) {
                case .success(let l): loaded = l; renewed = true      // retry exactly once
                case .failure(let f): return .failure(f.issue, hard: f.hard)
                }
            } catch QuotaError.transport {
                return .failure(.network, hard: false)
            } catch QuotaError.http(let code) {
                return .failure(.server(code), hard: false)
            } catch {
                return .failure(.other, hard: false)
            }
        }
    }

    /// Obtains usable credentials: adopts a refresh the CLI already did, or refreshes and writes back.
    private func renew(_ current: Loaded, backend: any QuotaBackend) async -> Result<Loaded, Fail> {
        let cli = backend.cliName
        guard backend.refreshPolicy == .selfRefresh else {
            // CLI owns the chain: look once more in case it renewed meanwhile, otherwise ask the user.
            if let fresh = try? current.store.read(), let c = backend.parseCredentials(fresh),
               c.accessToken != current.credentials.accessToken, !c.isExpired(at: now()) {
                return .success(Loaded(store: current.store, raw: fresh, credentials: c))
            }
            return .failure(Fail(.loginExpired(cli: cli), true))
        }

        // Re-read right before refreshing: the CLI may have refreshed (and rotated) already.
        guard let freshRaw = try? current.store.read(), let fresh = backend.parseCredentials(freshRaw) else {
            return .failure(Fail(.notSignedIn, false))
        }
        if fresh.accessToken != current.credentials.accessToken, !fresh.isExpired(at: now()) {
            return .success(Loaded(store: current.store, raw: freshRaw, credentials: fresh))
        }
        guard fresh.refreshToken?.isEmpty == false, let request = backend.refreshRequest(for: fresh) else {
            return .failure(Fail(.loginExpired(cli: cli), true))
        }
        // Prove write access BEFORE spending a rotating refresh token.
        do { try current.store.checkWritable() } catch CredentialStoreError.denied {
            return .failure(Fail(.accessDenied, true))
        } catch {
            return .failure(Fail(.cannotWriteBack(cli: cli), true))
        }

        let response: HTTPResponse
        do { response = try await http.send(request) } catch { return .failure(Fail(.network, false)) }
        guard (200..<300).contains(response.status) else {
            if response.status == 400 || response.status == 401 || response.status == 403 {
                return .failure(Fail(.loginExpired(cli: cli), true))
            }
            return .failure(Fail(.server(response.status), false))
        }

        // Compare-and-swap: if the CLI changed its store while we were refreshing, keep the CLI's version.
        guard let latestRaw = try? current.store.read() else { return .failure(Fail(.notSignedIn, false)) }
        if let latest = backend.parseCredentials(latestRaw), latest.refreshToken != fresh.refreshToken {
            return .success(Loaded(store: current.store, raw: latestRaw, credentials: latest))
        }
        guard let updatedRaw = backend.applyRefresh(response: response.body, to: latestRaw, now: now()),
              let updated = backend.parseCredentials(updatedRaw) else {
            return .failure(Fail(.other, false))
        }
        // Tokens are already rotated at this point, so losing the write would log the CLI out:
        // try a few times before giving up.
        var written = false
        for attempt in 0..<3 where !written {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 200_000_000) }
            written = (try? current.store.write(updatedRaw)) != nil
        }
        guard written else { return .failure(Fail(.cannotWriteBack(cli: cli), true)) }
        return .success(Loaded(store: current.store, raw: updatedRaw, credentials: updated))
    }
}
