import Foundation

/// Fetches Muse (muse.ai) usage per account with throttling comparable to `QuotaService`:
/// - a successful result is reused for `minInterval` (5 min); a manual refresh may go after `manualMinInterval` (30 s);
/// - failures back off exponentially from `baseBackoff` up to `maxBackoff` (1 h); a manual refresh skips the
///   backoff but still respects `manualMinInterval`;
/// - one request cycle in flight per account (a concurrent call returns the current state);
/// - a signed-out or expired session stops background retries until the stored cookies for that account change
///   (a manual refresh may still try again, at most every `manualMinInterval`);
/// - new cookies for an account (a re-sign-in) lift every throttle and block for it at once.
///
/// Cookies are read from `SecretStore` on every call, so the app only has to store them.
public actor MuseAIService {
    public struct Timing: Sendable {
        public var minInterval: TimeInterval = 300
        public var manualMinInterval: TimeInterval = 30
        public var baseBackoff: TimeInterval = 300
        public var maxBackoff: TimeInterval = 3600
        public init() {}
    }

    /// What the UI shows for one account.
    public struct State: Equatable, Sendable {
        /// Last successful read; kept while later attempts fail.
        public var usage: MuseAIUsage?
        /// Problem with the most recent attempt, nil after a success.
        public var failure: MuseAIFailure?
        /// When the last network attempt started.
        public var lastAttempt: Date?
        public init(usage: MuseAIUsage? = nil, failure: MuseAIFailure? = nil, lastAttempt: Date? = nil) {
            self.usage = usage
            self.failure = failure
            self.lastAttempt = lastAttempt
        }
    }

    private struct Entry {
        var state = State()
        var failures = 0
        var blockedUntil: Date?
        /// Session rejected or expired: no background attempts until the cookies change.
        var halted = false
        /// In-memory hash of the stored secret (never persisted or logged).
        var fingerprint: Int?
        var inFlight = false
    }

    private let fetcher: MuseAIFetcher
    private let secrets: SecretStore
    private let timing: Timing
    private let now: @Sendable () -> Date
    private var entries: [UUID: Entry] = [:]

    public init(fetcher: MuseAIFetcher = MuseAIFetcher(),
                secrets: SecretStore,
                timing: Timing = Timing(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.fetcher = fetcher
        self.secrets = secrets
        self.timing = timing
        self.now = now
    }

    /// Refreshes several accounts one after another; returns the state of each.
    public func refresh(accountIDs: [UUID], force: Bool = false) async -> [UUID: State] {
        var out: [UUID: State] = [:]
        for id in accountIDs { out[id] = await refresh(accountID: id, force: force) }
        return out
    }

    /// Current state without any network activity.
    public func state(for accountID: UUID) -> State? { entries[accountID]?.state }

    /// Drops everything remembered for an account (call when the account is removed).
    public func forget(accountID: UUID) { entries[accountID] = nil }

    public func refresh(accountID: UUID, force: Bool = false) async -> State {
        var e = entries[accountID] ?? Entry()
        guard let secret = secrets.secret(for: accountID), let cookies = MuseAICookieSet(serialized: secret) else {
            e = Entry()
            e.state = State(failure: .signedOut)
            entries[accountID] = e
            return e.state
        }

        var hasher = Hasher()
        hasher.combine(secret)
        let fp = hasher.finalize()
        if e.fingerprint != fp {
            // New cookies (first use or a re-sign-in): start fresh but keep the last usage on screen.
            e = Entry(state: State(usage: e.state.usage), fingerprint: fp, inFlight: e.inFlight)
        }
        if e.inFlight { entries[accountID] = e; return e.state }

        let t = now()
        if cookies.isExpired(at: t) {
            e.state.failure = .sessionExpired
            e.halted = true
            entries[accountID] = e
            return e.state
        }
        if e.halted && !force { entries[accountID] = e; return e.state }
        let minGap = force ? timing.manualMinInterval : timing.minInterval
        if let last = e.state.lastAttempt, t.timeIntervalSince(last) < minGap { entries[accountID] = e; return e.state }
        if !force, !e.halted, let until = e.blockedUntil, t < until { entries[accountID] = e; return e.state }

        e.inFlight = true
        e.state.lastAttempt = t
        entries[accountID] = e

        let result = await fetcher.fetch(cookies: cookies)

        // Re-read: the account may have been forgotten or re-signed-in while we waited.
        guard var s = entries[accountID], s.fingerprint == fp else {
            if var other = entries[accountID] { other.inFlight = false; entries[accountID] = other; return other.state }
            return State()
        }
        s.inFlight = false
        switch result {
        case .success(let usage):
            s.state.usage = usage
            s.state.failure = nil
            s.failures = 0
            s.blockedUntil = nil
            s.halted = false
        case .failure(let failure):
            s.state.failure = failure
            if failure.needsSignIn {
                s.halted = true
                s.blockedUntil = nil
            } else {
                s.failures += 1
                let delay = min(timing.maxBackoff, timing.baseBackoff * pow(2, Double(s.failures - 1)))
                s.blockedUntil = now().addingTimeInterval(delay)
            }
        }
        entries[accountID] = s
        return s.state
    }
}
