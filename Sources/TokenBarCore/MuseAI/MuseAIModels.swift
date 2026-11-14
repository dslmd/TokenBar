import Foundation

/// Why Muse (muse.ai) usage could not be fetched. Carries no cookie values, URLs with
/// credentials or server bodies, so it is safe to show and to log.
public enum MuseAIFailure: Error, Equatable, Sendable, CustomStringConvertible {
    /// No stored session for the account; the user has to sign in.
    case signedOut
    /// muse.ai rejected the stored session (401/403 or a redirect to auth.muse.ai), or every
    /// stored cookie has expired. The user has to sign in again; background retries stop.
    case sessionExpired
    /// The subscription action could not be found or its response was not understood.
    case siteChanged
    /// Transport failure or the discovery time budget ran out.
    case network
    /// muse.ai answered with an unexpected HTTP status.
    case server(Int)

    /// Short sentence for the UI.
    public var message: String {
        switch self {
        case .signedOut: return "Not signed in to Muse"
        case .sessionExpired: return "Muse session expired. Sign in again"
        case .siteChanged: return "muse.ai changed and usage could not be read"
        case .network: return "Network unavailable, will retry later"
        case .server(let code): return "muse.ai returned an error (\(code))"
        }
    }

    /// True when only a new sign-in can fix the problem.
    public var needsSignIn: Bool { self == .signedOut || self == .sessionExpired }

    public var description: String { message }
}

/// Top-up tokens (purchased or from referrals). They sit outside the weekly allowance.
public struct MuseAITopUp: Equatable, Sendable {
    /// e.g. "Additional tokens".
    public var label: String
    /// e.g. "1.5B tokens left", or "$80.00 left" when muse.ai gives no label.
    public var value: String
    /// 0...1 share of the top-up that has been used.
    public var usedFraction: Double

    public init(label: String, value: String, usedFraction: Double) {
        self.label = label
        self.value = value
        self.usedFraction = usedFraction
    }
}

/// One successful read of the muse.ai subscription.
public struct MuseAIUsage: Equatable, Sendable {
    /// Plan name such as "Maximum", "Power" or "Muse Free".
    public var planName: String?
    /// Exactly one window labelled "Weekly" (muse.ai reports percentages only).
    public var windows: [QuotaWindow]
    /// e.g. "2.8B tokens left"; free plans omit it.
    public var tokensLeft: String?
    public var topUp: MuseAITopUp?
    /// End of the current billing period, when reported.
    public var renewsAt: Date?
    public var observedAt: Date

    public init(planName: String?, windows: [QuotaWindow], tokensLeft: String?, topUp: MuseAITopUp?,
                renewsAt: Date?, observedAt: Date) {
        self.planName = planName
        self.windows = windows
        self.tokensLeft = tokensLeft
        self.topUp = topUp
        self.renewsAt = renewsAt
        self.observedAt = observedAt
    }

    /// The same windows in the shape the rest of TokenBar uses for online quota.
    public var quotaObservation: QuotaObservation {
        QuotaObservation(observedAt: observedAt, windows: windows)
    }
}

/// Result of a cheap "is this session signed in" check (used by the sign-in window).
public enum MuseAISessionCheck: Equatable, Sendable {
    case signedIn
    case signedOut
    /// Network error or an unexpected status; no conclusion.
    case unknown
}

/// Tiny persistence seam for non-secret values (the deploy-specific action id).
public protocol MuseAIKeyValueStore: Sendable {
    func string(forKey key: String) -> String?
    func setString(_ value: String?, forKey key: String)
}

public final class MuseAIMemoryKeyValueStore: MuseAIKeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    public init(_ values: [String: String] = [:]) { self.values = values }
    public func string(forKey key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }
    public func setString(_ value: String?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }
}

/// `UserDefaults`-backed store. The action id is public site metadata, not a secret.
public struct MuseAIUserDefaultsStore: MuseAIKeyValueStore, @unchecked Sendable {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    public func setString(_ value: String?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}
