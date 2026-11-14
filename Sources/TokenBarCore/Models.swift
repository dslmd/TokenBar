import Foundation

/// Token counts split into the four buckets the UI shows.
///
/// Conventions (enforced by each parser):
/// - `input` excludes cache reads, i.e. it is "fresh" prompt tokens.
/// - `output` includes reasoning/thinking tokens.
/// - `cacheRead` / `cacheWrite` are cache hits and cache creations.
public struct TokenBreakdown: Codable, Equatable, Sendable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public static let zero = TokenBreakdown()

    public var isZero: Bool { self == .zero }
    /// Everything, including cache buckets.
    public var total: Int { input + output + cacheRead + cacheWrite }
    /// Input + output only.
    public var totalExcludingCache: Int { input + output }
    public var cache: Int { cacheRead + cacheWrite }

    public static func + (l: TokenBreakdown, r: TokenBreakdown) -> TokenBreakdown {
        TokenBreakdown(input: l.input + r.input, output: l.output + r.output,
                       cacheRead: l.cacheRead + r.cacheRead, cacheWrite: l.cacheWrite + r.cacheWrite)
    }

    public static func += (l: inout TokenBreakdown, r: TokenBreakdown) { l = l + r }

    /// Component-wise maximum. Used to merge repeated observations of the same
    /// message (streaming logs repeat a message with a growing `output_tokens`).
    public func componentMax(_ other: TokenBreakdown) -> TokenBreakdown {
        TokenBreakdown(input: max(input, other.input), output: max(output, other.output),
                       cacheRead: max(cacheRead, other.cacheRead), cacheWrite: max(cacheWrite, other.cacheWrite))
    }
}

/// One billable model call observed in a log.
public struct UsageEvent: Equatable, Sendable {
    /// Identity used for de-duplication; events with equal keys are the same call.
    public var key: String
    public var timestamp: Date
    public var model: String?
    public var tokens: TokenBreakdown

    public init(key: String, timestamp: Date, model: String? = nil, tokens: TokenBreakdown) {
        self.key = key
        self.timestamp = timestamp
        self.model = model
        self.tokens = tokens
    }
}

/// A rate-limit / quota window as reported in local data.
public struct QuotaWindow: Codable, Equatable, Sendable {
    public var label: String
    /// 0...100
    public var usedPercent: Double
    public var windowMinutes: Int?
    public var resetsAt: Date?

    public init(label: String, usedPercent: Double, windowMinutes: Int? = nil, resetsAt: Date? = nil) {
        self.label = label
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }

    /// True when the reset time has passed, so `usedPercent` describes an older window.
    public func isStale(at now: Date) -> Bool {
        if let r = resetsAt { return r <= now }
        return false
    }
}

/// Quota windows together with the moment they were recorded.
public struct QuotaObservation: Equatable, Sendable {
    public var observedAt: Date
    public var windows: [QuotaWindow]
    public init(observedAt: Date, windows: [QuotaWindow]) {
        self.observedAt = observedAt
        self.windows = windows
    }
}

/// A user-configured account for a provider.
public struct Account: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var providerID: String
    public var name: String
    /// Config/home directory of the CLI (e.g. `~/.claude`, `$CODEX_HOME`).
    /// Its exact meaning is defined by the provider (`UsageProvider.dataPathHint`).
    public var dataPath: String
    /// Per-account switch for online quota (network); local token counting is unaffected.
    public var onlineQuotaEnabled: Bool
    /// How the account was added. Nil for accounts saved by versions that did not record it.
    public var origin: AccountOrigin?
    /// True while the name is TokenBar's choice, so it follows the signed-in identity. Renaming clears it.
    public var autoNamed: Bool
    /// Disabled accounts stay in the list but are not scanned or shown in the popover.
    public var isEnabled: Bool

    public init(id: UUID = UUID(), providerID: String, name: String, dataPath: String, onlineQuotaEnabled: Bool = true,
                origin: AccountOrigin? = nil, autoNamed: Bool = false, isEnabled: Bool = true) {
        self.id = id
        self.providerID = providerID
        self.name = name
        self.dataPath = dataPath
        self.onlineQuotaEnabled = onlineQuotaEnabled
        self.origin = origin
        self.autoNamed = autoNamed
        self.isEnabled = isEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        providerID = try c.decode(String.self, forKey: .providerID)
        name = try c.decode(String.self, forKey: .name)
        dataPath = try c.decode(String.self, forKey: .dataPath)
        onlineQuotaEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .onlineQuotaEnabled)) ?? true
        origin = (try? c.decodeIfPresent(AccountOrigin.self, forKey: .origin)) ?? nil
        autoNamed = (try? c.decodeIfPresent(Bool.self, forKey: .autoNamed)) ?? Self.isLegacyDefaultName(name)
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? true
    }

    /// Names generated by version 0.2 ("Default" and "Account N" in its former UI language). Accounts that
    /// still carry one are renamed automatically after the signed-in identity.
    static func isLegacyDefaultName(_ name: String) -> Bool {
        let legacyDefault = "\u{9ED8}\u{8BA4}"
        let legacyAccount = "\u{8D26}\u{6237} "
        if name == legacyDefault { return true }
        if name.hasPrefix(legacyAccount), Int(name.dropFirst(legacyAccount.count)) != nil { return true }
        return false
    }
}

/// Tokens for one calendar day (start of day in the scan calendar).
public struct DailyUsage: Equatable, Sendable {
    public var day: Date
    public var tokens: TokenBreakdown
    public init(day: Date, tokens: TokenBreakdown = .zero) {
        self.day = day
        self.tokens = tokens
    }
}

public enum ScanStatus: Equatable, Sendable {
    case ok
    case unknownProvider
    /// None of the provider's log directories exist.
    case dataDirectoryMissing
    /// Directories exist but contain no usage inside the retention window.
    case noRecentData
}

/// Aggregated result for one account.
public struct AccountUsage: Equatable, Sendable {
    public var today: TokenBreakdown
    public var last7Days: TokenBreakdown
    public var month: TokenBreakdown
    /// Seven entries, oldest first, ending with today.
    public var daily: [DailyUsage]
    /// Quota found in local logs (Codex only). Online quota is reported separately by `QuotaService`.
    public var quota: QuotaObservation?
    public var lastActivity: Date?
    public var updatedAt: Date
    public var filesTracked: Int
    public var status: ScanStatus

    public init(today: TokenBreakdown = .zero, last7Days: TokenBreakdown = .zero, month: TokenBreakdown = .zero,
                daily: [DailyUsage] = [],
                quota: QuotaObservation? = nil, lastActivity: Date? = nil, updatedAt: Date,
                filesTracked: Int = 0, status: ScanStatus = .ok) {
        self.today = today
        self.last7Days = last7Days
        self.month = month
        self.daily = daily
        self.quota = quota
        self.lastActivity = lastActivity
        self.updatedAt = updatedAt
        self.filesTracked = filesTracked
        self.status = status
    }
}
