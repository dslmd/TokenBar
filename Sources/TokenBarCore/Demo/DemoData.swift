import Foundation

/// Everything `AppModel` shows, as plain values. Used to run the real views with made-up data
/// (UI snapshots, design work) without reading accounts, logs, the Keychain or the network.
public struct DemoState: Sendable {
    public var config: AppConfig
    public var usage: [UUID: AccountUsage]
    public var quota: [UUID: QuotaResult]
    public var identities: [UUID: AccountIdentity]
    public var webQuota: [UUID: MuseAIService.State]
    public var signInPhases: [String: LoginPhase]
    public var hasScanned: Bool
    public var isScanning: Bool
    public var lastRefresh: Date?

    public init(config: AppConfig = AppConfig(), usage: [UUID: AccountUsage] = [:], quota: [UUID: QuotaResult] = [:],
                identities: [UUID: AccountIdentity] = [:], webQuota: [UUID: MuseAIService.State] = [:],
                signInPhases: [String: LoginPhase] = [:], hasScanned: Bool = true, isScanning: Bool = false,
                lastRefresh: Date? = nil) {
        self.config = config
        self.usage = usage
        self.quota = quota
        self.identities = identities
        self.webQuota = webQuota
        self.signInPhases = signInPhases
        self.hasScanned = hasScanned
        self.isScanning = isScanning
        self.lastRefresh = lastRefresh
    }
}

/// Made-up situations for UI snapshots. Every name and email is fake (example.com).
public enum DemoScenario: String, CaseIterable, Sendable {
    /// Several accounts on every provider, with quota problems mixed in.
    case rich
    /// The rich accounts while two sign-ins from settings are in progress or failed.
    case signingIn
    /// One account with little usage.
    case sparse
    /// First run: the scan finished and found nothing.
    case empty
    /// First run: the scan has not finished yet.
    case scanning
    /// Accounts exist but all are turned off.
    case allOff
    /// Accounts exist but nothing has been read yet (the first seconds after launch).
    case loading

    /// - Parameters:
    ///   - now: the moment the snapshot pretends to be taken.
    ///   - home: the user's home directory, only used to spell account paths.
    public func state(now: Date = Date(), calendar: Calendar = .current, home: String) -> DemoState {
        let b = DemoBuilder(now: now, calendar: calendar, home: home)
        switch self {
        case .rich: return b.rich()
        case .signingIn:
            var s = b.rich()
            s.signInPhases = [
                "codex": .waitingForUser(hint: "Continue in your browser to sign in to Codex."),
                "gemini": .failed(message: "Gemini CLI is not installed. Install it with: npm install -g @google/gemini-cli"),
            ]
            return s
        case .sparse: return b.sparse()
        case .empty: return DemoState(hasScanned: true, lastRefresh: now.addingTimeInterval(-20))
        case .scanning: return DemoState(hasScanned: false, isScanning: true)
        case .allOff:
            var s = b.sparse(second: true)
            for i in s.config.accounts.indices { s.config.accounts[i].isEnabled = false }
            s.usage = [:]
            s.quota = [:]
            return s
        case .loading:
            var s = b.rich()
            s.usage = [:]
            s.quota = [:]
            s.webQuota = [:]
            s.lastRefresh = nil
            return s
        }
    }
}

/// Fixed account ids so snapshots are stable from run to run.
enum DemoID {
    static func make(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "DE300000-0000-4000-8000-%012d", n)) ?? UUID()
    }
    static let claudeMain = make(1)
    static let claudeWork = make(2)
    static let codex = make(3)
    static let gemini = make(4)
    static let museMax = make(5)
    static let museFree = make(6)
    static let museCode = make(7)
}

struct DemoBuilder {
    let now: Date
    let calendar: Calendar
    let home: String

    private func ago(minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
    private func ahead(hours: Double) -> Date { now.addingTimeInterval(hours * 3600) }

    /// Splits a number of fresh (non-cache) tokens into the four buckets.
    static func breakdown(_ fresh: Int, outputShare: Double, cacheFactor: Double) -> TokenBreakdown {
        let output = Int(Double(fresh) * outputShare)
        let cacheRead = Int(Double(fresh) * cacheFactor)
        return TokenBreakdown(input: fresh - output, output: output, cacheRead: cacheRead, cacheWrite: cacheRead / 9)
    }

    /// - Parameters:
    ///   - week: fresh tokens per day, oldest first, ending with today (seven values).
    ///   - earlierThisMonth: fresh tokens used this month before those seven days.
    func usage(week: [Int], earlierThisMonth: Int, outputShare: Double, cacheFactor: Double,
               lastActiveMinutesAgo: Double?, quota: QuotaObservation? = nil, files: Int,
               status: ScanStatus = .ok) -> AccountUsage {
        let today = calendar.startOfDay(for: now)
        var daily: [DailyUsage] = []
        var last7 = TokenBreakdown.zero
        for (i, fresh) in week.enumerated() {
            let day = calendar.date(byAdding: .day, value: i - (week.count - 1), to: today) ?? today
            let tokens = Self.breakdown(fresh, outputShare: outputShare, cacheFactor: cacheFactor)
            daily.append(DailyUsage(day: day, tokens: tokens))
            last7 += tokens
        }
        let month = last7 + Self.breakdown(earlierThisMonth, outputShare: outputShare, cacheFactor: cacheFactor)
        return AccountUsage(today: daily.last?.tokens ?? .zero, last7Days: last7, month: month, daily: daily,
                            quota: quota, lastActivity: lastActiveMinutesAgo.map { ago(minutes: $0) },
                            updatedAt: ago(minutes: 0.3), filesTracked: files, status: status)
    }

    func rich() -> DemoState {
        let managed = home + "/Library/Application Support/TokenBar/accounts"
        let accounts = [
            Account(id: DemoID.claudeMain, providerID: "claude", name: "alex@example.com", dataPath: home + "/.claude",
                    origin: .detected, autoNamed: true),
            Account(id: DemoID.claudeWork, providerID: "claude", name: "sam.rivera@example.com",
                    dataPath: managed + "/claude/7C1D8B52-3A44-4E0B-9E57-0D5B6F2A9C11", origin: .signedIn, autoNamed: true),
            Account(id: DemoID.codex, providerID: "codex", name: "alex@example.com", dataPath: home + "/.codex",
                    origin: .detected, autoNamed: true),
            Account(id: DemoID.gemini, providerID: "gemini", name: "alex.dev@example.com", dataPath: home + "/.gemini",
                    origin: .detected, autoNamed: true),
            Account(id: DemoID.museMax, providerID: ProviderCatalog.museAIID, name: "Muse Maximum", dataPath: "",
                    origin: .signedIn),
            Account(id: DemoID.museFree, providerID: ProviderCatalog.museAIID, name: "Muse Free", dataPath: "",
                    origin: .signedIn),
            Account(id: DemoID.museCode, providerID: "muse", name: "Default", dataPath: home + "/.local/share/muse/sessions",
                    origin: .detected, autoNamed: true),
        ]

        let codexWindows = [
            QuotaWindow(label: "5-hour", usedPercent: 41, windowMinutes: 300, resetsAt: ahead(hours: 3.2)),
            QuotaWindow(label: "Weekly", usedPercent: 67, windowMinutes: 10080, resetsAt: ahead(hours: 4 * 24 + 6)),
        ]

        let usage: [UUID: AccountUsage] = [
            // Heavy user, close to the weekly limit.
            DemoID.claudeMain: usage(week: [1_840_000, 2_610_000, 420_000, 0, 3_120_000, 2_250_000, 1_370_000],
                                     earlierThisMonth: 9_400_000, outputShare: 0.34, cacheFactor: 11.5,
                                     lastActiveMinutesAgo: 4, files: 212),
            // Signed in from TokenBar, moderate use, sign-in has expired.
            DemoID.claudeWork: usage(week: [0, 310_000, 505_000, 96_000, 0, 0, 148_000],
                                     earlierThisMonth: 1_200_000, outputShare: 0.29, cacheFactor: 8,
                                     lastActiveMinutesAgo: 190, files: 37),
            DemoID.codex: usage(week: [220_000, 0, 615_000, 890_000, 340_000, 71_000, 486_000],
                                earlierThisMonth: 2_950_000, outputShare: 0.18, cacheFactor: 4.2,
                                lastActiveMinutesAgo: 26,
                                quota: QuotaObservation(observedAt: ago(minutes: 26), windows: codexWindows), files: 88),
            DemoID.gemini: usage(week: [0, 0, 44_000, 12_500, 0, 131_000, 9_800],
                                 earlierThisMonth: 260_000, outputShare: 0.22, cacheFactor: 1.6,
                                 lastActiveMinutesAgo: 75, files: 14),
            DemoID.museCode: usage(week: [0, 18_000, 0, 0, 52_000, 7_400, 0],
                                   earlierThisMonth: 40_000, outputShare: 0.4, cacheFactor: 0.5,
                                   lastActiveMinutesAgo: 60 * 26, files: 5),
        ]

        let quota: [UUID: QuotaResult] = [
            DemoID.claudeMain: QuotaResult(observation: QuotaObservation(observedAt: ago(minutes: 2), windows: [
                QuotaWindow(label: "5-hour", usedPercent: 62, windowMinutes: 300, resetsAt: ahead(hours: 2.2)),
                QuotaWindow(label: "Weekly", usedPercent: 93, windowMinutes: 10080, resetsAt: ahead(hours: 2 * 24 + 5)),
                QuotaWindow(label: "Weekly (Opus)", usedPercent: 71, windowMinutes: 10080, resetsAt: ahead(hours: 2 * 24 + 5)),
            ])),
            // The last good reading stays on screen while the sign-in is expired; its 5-hour window has reset since.
            DemoID.claudeWork: QuotaResult(observation: QuotaObservation(observedAt: ago(minutes: 200), windows: [
                QuotaWindow(label: "5-hour", usedPercent: 18, windowMinutes: 300, resetsAt: ago(minutes: 50)),
                QuotaWindow(label: "Weekly", usedPercent: 38, windowMinutes: 10080, resetsAt: ahead(hours: 5 * 24 + 2)),
            ]), issue: .loginExpired(cli: "claude")),
            DemoID.codex: QuotaResult(observation: QuotaObservation(observedAt: ago(minutes: 3), windows: codexWindows)),
            DemoID.gemini: QuotaResult(observation: QuotaObservation(observedAt: ago(minutes: 4), windows: [
                QuotaWindow(label: "Pro", usedPercent: 22, resetsAt: ahead(hours: 9.5)),
                QuotaWindow(label: "Flash", usedPercent: 8, resetsAt: ahead(hours: 9.5)),
                QuotaWindow(label: "Flash Lite", usedPercent: 0, resetsAt: ahead(hours: 9.5)),
            ])),
            DemoID.museCode: QuotaResult(issue: .unsupported),
        ]

        let identities: [UUID: AccountIdentity] = [
            DemoID.claudeMain: AccountIdentity(email: "alex@example.com", plan: "max", organization: "Example Labs", isSignedIn: true),
            DemoID.claudeWork: AccountIdentity(email: "sam.rivera@example.com", plan: "pro", isSignedIn: true),
            DemoID.codex: AccountIdentity(email: "alex@example.com", plan: "plus", isSignedIn: true),
            DemoID.gemini: AccountIdentity(email: "alex.dev@example.com", isSignedIn: true),
        ]

        let weekly = QuotaWindow(label: "Weekly", usedPercent: 54, windowMinutes: 10080, resetsAt: ahead(hours: 3 * 24 + 11))
        let webQuota: [UUID: MuseAIService.State] = [
            DemoID.museMax: MuseAIService.State(
                usage: MuseAIUsage(planName: "Maximum", windows: [weekly], tokensLeft: "2.8B tokens left",
                                   topUp: MuseAITopUp(label: "Additional tokens", value: "1.5B tokens left", usedFraction: 0.25),
                                   renewsAt: ahead(hours: 19 * 24), observedAt: ago(minutes: 3)),
                lastAttempt: ago(minutes: 3)),
            // Session rejected by muse.ai: the user has to sign in again.
            DemoID.museFree: MuseAIService.State(failure: .sessionExpired, lastAttempt: ago(minutes: 3)),
        ]

        return DemoState(config: AppConfig(accounts: accounts), usage: usage, quota: quota, identities: identities,
                         webQuota: webQuota, hasScanned: true, lastRefresh: ago(minutes: 0.3))
    }

    /// One Claude Code account with little usage. `second` adds a Codex account (for the "all turned off" state).
    func sparse(second: Bool = false) -> DemoState {
        var accounts = [
            Account(id: DemoID.claudeMain, providerID: "claude", name: "alex@example.com", dataPath: home + "/.claude",
                    origin: .detected, autoNamed: true),
        ]
        var usage: [UUID: AccountUsage] = [
            DemoID.claudeMain: usage(week: [0, 0, 0, 3_100, 0, 0, 12_400], earlierThisMonth: 0,
                                     outputShare: 0.3, cacheFactor: 2.5, lastActiveMinutesAgo: 12, files: 2),
        ]
        var quota: [UUID: QuotaResult] = [
            DemoID.claudeMain: QuotaResult(observation: QuotaObservation(observedAt: ago(minutes: 1), windows: [
                QuotaWindow(label: "5-hour", usedPercent: 3, windowMinutes: 300, resetsAt: ahead(hours: 4.6)),
                QuotaWindow(label: "Weekly", usedPercent: 1, windowMinutes: 10080, resetsAt: ahead(hours: 6 * 24 + 20)),
            ])),
        ]
        var identities: [UUID: AccountIdentity] = [
            DemoID.claudeMain: AccountIdentity(email: "alex@example.com", plan: "pro", isSignedIn: true),
        ]
        if second {
            accounts.append(Account(id: DemoID.codex, providerID: "codex", name: "alex@example.com", dataPath: home + "/.codex",
                                    origin: .detected, autoNamed: true))
            usage[DemoID.codex] = self.usage(week: [0, 0, 0, 0, 0, 0, 0], earlierThisMonth: 0, outputShare: 0.2,
                                             cacheFactor: 1, lastActiveMinutesAgo: nil, files: 0, status: .noRecentData)
            quota[DemoID.codex] = QuotaResult(issue: .notSignedIn)
            identities[DemoID.codex] = AccountIdentity(email: "alex@example.com", plan: "plus", isSignedIn: true)
        }
        return DemoState(config: AppConfig(accounts: accounts), usage: usage, quota: quota, identities: identities,
                         hasScanned: true, lastRefresh: ago(minutes: 0.3))
    }
}

/// A sign-in driver that does nothing, so demo runs never look for CLIs, start processes or touch managed homes.
public struct DemoLoginDriver: AccountLoginDriving {
    private struct Handle: LoginHandle {
        func cancel() {}
    }

    public let managedRootPath: String

    public init(managedRootPath: String) {
        self.managedRootPath = managedRootPath
    }

    public func unavailableReason(providerID: String) -> String? {
        LoginProviderSpec.unavailableReason(for: providerID)
    }

    public func start(providerID: String, onPhase: @escaping @Sendable (LoginPhase) -> Void) -> LoginHandle {
        onPhase(.failed(message: "Sign-in is not available in demo mode."))
        return Handle()
    }

    public func shellAlias(providerID: String, homePath: String) -> String? { nil }

    public func removeManagedHome(at homePath: String) {}

    public func isManagedHome(_ path: String) -> Bool {
        path.hasPrefix(managedRootPath + "/")
    }
}
