import Foundation

/// Decisions behind the menu bar window (overview, account detail) and the menu bar label, kept out of the
/// views so they can be tested. Every text here is English and deterministic (no locale).

/// Which top-level content the popover shows.
public enum PopoverScreen: Equatable, Sendable {
    /// The first scan has not finished (and nothing is turned on yet).
    case scanning
    /// The scan finished and found no accounts.
    case noAccounts
    /// Accounts exist but every one is turned off.
    case allTurnedOff
    /// At least one account is turned on.
    case accounts

    public static func resolve(hasScanned: Bool, isScanning: Bool, accountCount: Int, enabledCount: Int) -> PopoverScreen {
        if enabledCount > 0 { return .accounts }
        if !hasScanned || isScanning { return .scanning }
        return accountCount > 0 ? .allTurnedOff : .noAccounts
    }
}

/// What the detail page of an account contains.
public enum AccountDetailKind: Equatable, Sendable {
    /// Token numbers from local logs plus quota windows (Claude Code, Codex, Gemini CLI).
    case logsWithQuota
    /// Quota read from a website session only, no token numbers (Muse).
    case webQuota
    /// Token numbers only, no quota (Muse Code).
    case logsOnly

    public init(_ capabilities: ProviderCapabilities) {
        if !capabilities.localLogs { self = .webQuota }
        else if capabilities.hasOnlineQuota { self = .logsWithQuota }
        else { self = .logsOnly }
    }

    public var showsTokens: Bool { self != .webQuota }
    public var showsQuota: Bool { self != .logsOnly }
}

/// One quota window reduced to what a single line needs: "Weekly 93% · resets in 2 days".
public struct QuotaSummary: Equatable, Sendable {
    public var label: String
    /// Rounded down, 0...100, so 89.6 % never reads as the critical "90%".
    public var percent: Int
    public var level: QuotaLevel
    /// "resets in 2 days"; nil when the reset time is unknown.
    public var resetPhrase: String?
    /// Bar fill, 0...1 (0 for a window that has reset since it was read).
    public var fraction: Double

    public init(window: QuotaWindow, now: Date) {
        label = window.label
        let clamped = min(100, max(0, window.usedPercent))
        percent = Int(clamped.rounded(.down))
        level = QuotaLevel(window: window, now: now)
        if level == .stale {
            resetPhrase = nil
            fraction = 0
        } else {
            resetPhrase = window.resetsAt.map { "resets " + ResetPhrase.until($0, now: now) }
            fraction = clamped / 100
        }
    }

    public var percentText: String { "\(percent)%" }

    /// "Weekly 93% · resets in 2 days" (row line).
    public var text: String {
        ["\(label) \(percentText)", resetPhrase].compactMap { $0 }.joined(separator: " · ")
    }

    /// Right-hand side of a detail quota row: "resets in 2 hr", or the stale note.
    public var detailNote: String? {
        level == .stale ? "Window reset, updates after use" : resetPhrase
    }
}

/// The window closest to running out over all accounts, for the header of the overview.
public struct PeakQuota: Equatable, Sendable {
    public var accountID: UUID
    public var providerName: String
    public var summary: QuotaSummary

    /// "Weekly 93% · Claude Code · resets in 2 days".
    public var text: String {
        ["\(summary.label) \(summary.percentText)", providerName, summary.resetPhrase].compactMap { $0 }
            .joined(separator: " · ")
    }

    public struct Candidate: Sendable {
        public var accountID: UUID
        public var providerName: String
        public var windows: [QuotaWindow]
        public init(accountID: UUID, providerName: String, windows: [QuotaWindow]) {
            self.accountID = accountID
            self.providerName = providerName
            self.windows = windows
        }
    }

    /// The highest current (not reset) window; on a tie the earlier candidate wins. Nil without quota.
    public static func find(_ candidates: [Candidate], now: Date) -> PeakQuota? {
        var best: (Candidate, QuotaWindow)?
        for candidate in candidates {
            guard let window = QuotaMerge.peakWindow(candidate.windows, now: now) else { continue }
            if best.map({ window.usedPercent > $0.1.usedPercent }) ?? true { best = (candidate, window) }
        }
        guard let (candidate, window) = best else { return nil }
        return PeakQuota(accountID: candidate.accountID, providerName: candidate.providerName,
                         summary: QuotaSummary(window: window, now: now))
    }
}

/// The second line of an account row in the overview.
public enum AccountRowLine: Equatable, Sendable {
    /// Nothing read yet: small spinner and "Reading…".
    case reading
    /// A problem the user has to act on; replaces the quota line.
    case attention(String)
    /// Muse with online quota off: nothing can be read.
    case onlineQuotaOff
    case quota(QuotaSummary)
    /// No quota (Muse Code, or no window known): "Last active 1 day ago".
    case lastActive(Date)
    case noRecentUsage
    case none

    public struct Input: Sendable {
        public var kind: AccountDetailKind
        /// Local usage was read (log accounts) or a muse.ai reading exists (web accounts).
        public var hasData: Bool
        /// `AppModel.attentionMessage(for:)`.
        public var attention: String?
        public var onlineQuotaOn: Bool
        public var windows: [QuotaWindow]
        public var lastActivity: Date?
        public var noRecentData: Bool

        public init(kind: AccountDetailKind, hasData: Bool, attention: String? = nil, onlineQuotaOn: Bool = true,
                    windows: [QuotaWindow] = [], lastActivity: Date? = nil, noRecentData: Bool = false) {
            self.kind = kind
            self.hasData = hasData
            self.attention = attention
            self.onlineQuotaOn = onlineQuotaOn
            self.windows = windows
            self.lastActivity = lastActivity
            self.noRecentData = noRecentData
        }
    }

    public static func resolve(_ input: Input, now: Date) -> AccountRowLine {
        if let attention = input.attention { return .attention(attention) }
        if input.kind == .webQuota {
            guard input.onlineQuotaOn else { return .onlineQuotaOff }
            guard input.hasData else { return .reading }
            return QuotaMerge.peakWindow(input.windows, now: now).map { .quota(QuotaSummary(window: $0, now: now)) } ?? .none
        }
        guard input.hasData else { return .reading }
        if input.kind == .logsWithQuota {
            if let peak = QuotaMerge.peakWindow(input.windows, now: now) {
                return .quota(QuotaSummary(window: peak, now: now))
            }
            // Say why the quota bar is missing, as the Muse rows do. Quota from local logs still wins above.
            if input.windows.isEmpty && !input.onlineQuotaOn { return .onlineQuotaOff }
        }
        if let last = input.lastActivity { return .lastActive(last) }
        return input.noRecentData ? .noRecentUsage : .none
    }
}

/// Short English phrases for the past, e.g. "just now", "2 min ago", "3 hr ago", "1 day ago".
public enum AgoPhrase {
    public static func since(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = Int(seconds / 3600)
        if hours < 24 { return "\(hours) hr ago" }
        let days = Int(seconds / 86400)
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }
}

/// Small texts of the overview and the detail page.
public enum PopoverText {
    /// "Updated 1 min ago", or "Reading…" before the first refresh.
    public static func footer(lastRefresh: Date?, now: Date) -> String {
        guard let lastRefresh else { return "Reading…" }
        return "Updated " + AgoPhrase.since(lastRefresh, now: now)
    }

    /// Where the quota shown on the detail page comes from: "From online check, 2 min ago".
    public static func quotaSource(kind: AccountDetailKind, isOnline: Bool, observedAt: Date, now: Date) -> String {
        let source = kind == .webQuota ? "From muse.ai" : (isOnline ? "From online check" : "From local logs")
        return source + ", " + AgoPhrase.since(observedAt, now: now)
    }

    /// Identity line under the account name: plan and organization, plus the email when the account
    /// is not already named after it. Nil when nothing is known.
    public static func identityLine(accountName: String, identity: AccountIdentity?) -> String? {
        guard let identity else { return nil }
        var parts: [String] = []
        if let email = identity.email, email.caseInsensitiveCompare(accountName) != .orderedSame { parts.append(email) }
        if let plan = identity.planLabel { parts.append(plan) }
        if let organization = identity.organization, !organization.isEmpty { parts.append(organization) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Maximum plan" for a Muse account; nil when the plan is unknown or already the account's name.
    public static func planLine(accountName: String, planName: String?) -> String? {
        guard let plan = planName?.trimmingCharacters(in: .whitespaces), !plan.isEmpty else { return nil }
        if plan.caseInsensitiveCompare(accountName) == .orderedSame { return nil }
        return plan.lowercased().hasSuffix("plan") ? plan : plan + " plan"
    }

    /// "2.8B tokens left" becomes "2.8B left", so amounts read alike next to their own label.
    public static func amountLeft(_ text: String) -> String {
        let suffix = " tokens left"
        guard text.hasSuffix(suffix), text.count > suffix.count else { return text }
        return String(text.dropLast(suffix.count)) + " left"
    }

    /// The hero number of the overview: like `TokenFormatter.compact` but keeps one decimal below 10 of a
    /// unit ("2.0M", not "2M"), so it reads as precisely as the section totals under it.
    public static func heroTokens(_ n: Int) -> String {
        let v = Double(abs(n))
        let sign = n < 0 ? "-" : ""
        func fmt(_ x: Double, _ suffix: String) -> String {
            sign + String(format: x >= 9.95 ? "%.0f" : "%.1f", x) + suffix
        }
        switch v {
        case 999_500_000...: return fmt(v / 1_000_000_000, "B")
        case 999_500...: return fmt(v / 1_000_000, "M")
        case 1_000...: return fmt(v / 1_000, "K")
        default: return "\(n)"
        }
    }

    /// "A", "A and B", "A, B and C".
    public static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    /// Body of the "No accounts yet" state, built from the provider catalog.
    /// - Parameters:
    ///   - localProviders: providers TokenBar finds on its own (local logs).
    ///   - webProviders: providers added by signing in (Muse).
    public static func noAccounts(localProviders: [String], webProviders: [String]) -> String {
        var sentences: [String] = []
        if !localProviders.isEmpty { sentences.append("TokenBar looks for \(list(localProviders)) on this Mac.") }
        if !webProviders.isEmpty { sentences.append("Sign in to add \(list(webProviders)).") }
        return sentences.joined(separator: " ")
    }

    /// Ends a status message with a period, so short attention texts read as sentences.
    public static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last, !".?…)".contains(last) else { return trimmed }
        return trimmed + "."
    }

    /// The problem part of a Muse failure, for when a "Sign in again…" button sits right under it.
    public static func museProblem(_ failure: MuseAIFailure) -> String {
        switch failure {
        case .sessionExpired: return "Your Muse session expired."
        case .signedOut: return "You're not signed in to Muse."
        default: return sentence(failure.message)
        }
    }

    /// "Renews in 19 days"; nil without a date or when it has passed.
    public static func renewal(_ date: Date?, now: Date) -> String? {
        guard let date, date > now else { return nil }
        return "Renews " + ResetPhrase.until(date, now: now)
    }
}

/// Content of the menu bar label.
public struct MenuBarLabelContent: Equatable, Sendable {
    public var symbolName: String
    /// Nil when only the icon is shown.
    public var text: String?
    public var accessibilityLabel: String

    public init(title: String, showsNumber: Bool, warning: Bool, metric: MenuBarMetric, period: MenuBarPeriod) {
        symbolName = warning ? "exclamationmark.triangle.fill" : "chart.bar.fill"
        // Without data the title is a placeholder dash: show only the symbol then.
        text = (showsNumber && title != "–") ? title : nil
        var parts = ["TokenBar"]
        if warning { parts.append("quota almost used up") }
        if title != "–" {
            switch metric {
            case .tokens:
                let when: String
                switch period {
                case .today: when = "today"
                case .last7Days: when = "in the last 7 days"
                case .month: when = "this month"
                }
                parts.append("\(title) tokens \(when)")
            case .peakQuota:
                parts.append("highest quota \(title)")
            }
        }
        accessibilityLabel = parts.joined(separator: ", ")
    }
}
