import Foundation

/// How close a quota window is to running out. The thresholds match the menu bar warning (90 %).
public enum QuotaLevel: Equatable, Sendable {
    case normal
    case elevated
    case critical
    /// The window has reset since it was read, so its percentage is out of date.
    case stale

    public static let elevatedFrom: Double = 75
    public static let criticalFrom: Double = 90

    public init(percent: Double) {
        switch percent {
        case ..<Self.elevatedFrom: self = .normal
        case ..<Self.criticalFrom: self = .elevated
        default: self = .critical
        }
    }

    public init(window: QuotaWindow, now: Date) {
        self = window.isStale(at: now) ? .stale : QuotaLevel(percent: window.usedPercent)
    }
}

public extension QuotaMerge {
    /// The current (not yet reset) window with the highest used percentage, for one-line summaries.
    static func peakWindow(_ windows: [QuotaWindow], now: Date) -> QuotaWindow? {
        windows.filter { !$0.isStale(at: now) }.max { $0.usedPercent < $1.usedPercent }
    }
}

/// Short English phrases for reset times, e.g. "in 25 min", "in 3 hr", "in 2 days".
/// Deterministic (no locale), so notification texts can be tested.
public enum ResetPhrase {
    public static func until(_ date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 60 { return "in less than a minute" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "in \(minutes) min" }
        let hours = Int((seconds / 3600).rounded())
        if hours < 24 { return "in \(hours) hr" }
        let days = Int((seconds / 86400).rounded())
        return days == 1 ? "in 1 day" : "in \(days) days"
    }
}
