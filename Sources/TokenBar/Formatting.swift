import Foundation
import TokenBarCore

/// Display helpers. Dates and relative times follow the user's current locale.
enum Fmt {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEE")     // narrow weekday, e.g. "M"
        return f
    }()

    private static let dayMonthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    static func relative(_ date: Date, to now: Date = Date()) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    static func weekdayInitial(_ d: Date) -> String { weekday.string(from: d) }
    static func dayMonth(_ d: Date) -> String { dayMonthFormatter.string(from: d) }

    static func clockTime(_ date: Date) -> String { clock.string(from: date) }

    static func tokens(_ n: Int) -> String { TokenFormatter.compact(n) }

    static func periodTitle(_ p: MenuBarPeriod) -> String {
        switch p {
        case .today: return "Today"
        case .last7Days: return "Last 7 days"
        case .month: return "This month"
        }
    }

    static func statusText(_ s: ScanStatus) -> String? {
        switch s {
        case .ok: return nil
        case .unknownProvider: return "Unknown provider"
        case .dataDirectoryMissing: return "Folder not found. Check it in Settings"
        case .noRecentData: return "No usage this month"
        }
    }

    /// "work@example.com · Max · Acme", or nil when nothing is known.
    static func identityLine(_ identity: AccountIdentity?) -> String? {
        guard let identity else { return nil }
        let parts = [identity.email, identity.planLabel, identity.organization].compactMap { $0 }
        return parts.isEmpty ? (identity.isSignedIn ? "Signed in" : nil) : parts.joined(separator: " · ")
    }

    /// Home-relative path for display, e.g. "~/.claude-work".
    static func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
