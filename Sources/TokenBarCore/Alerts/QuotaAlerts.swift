import Foundation

/// A notification TokenBar wants to show. Texts are final: the app layer only hands them to the system.
public struct PendingAlert: Equatable, Sendable {
    /// Stable identifier; the same alert replaces itself instead of stacking.
    public let id: String
    public let accountID: UUID
    public let title: String
    public let subtitle: String
    public let body: String

    public init(id: String, accountID: UUID, title: String, subtitle: String, body: String) {
        self.id = id
        self.accountID = accountID
        self.title = title
        self.subtitle = subtitle
        self.body = body
    }
}

/// Decides which notifications to show after a refresh, and remembers what was already shown so a quota
/// alert fires once per window cycle and a sign-in alert once per problem.
///
/// The memory ("ledger") is a list of strings stored in `AppConfig.alertLedger`:
/// - `q|<account>|<window label>|<reset time>`: quota alert shown for this cycle. Dropped once the reset
///   time has passed, so the next cycle can alert again. Windows without a reset time use `-` and are
///   dropped when usage falls clearly below the threshold.
/// - `s|<account>`: sign-in alert shown. Dropped when the account is healthy again.
public enum QuotaAlerts {
    /// What is known about one enabled account after a refresh.
    public struct Input: Sendable {
        public var account: Account
        public var providerName: String
        /// Current quota windows (online data when present, otherwise local), possibly empty.
        public var windows: [QuotaWindow]
        /// A sign-in problem the user has to fix, as a sentence; nil when there is none.
        /// nil also when nothing is known yet: it never clears a remembered sign-in alert by itself
        /// unless `isKnown` is true.
        public var signInProblem: String?
        /// True when the latest refresh actually reached a verdict for this account (so a missing
        /// `signInProblem` means "fixed" rather than "not read yet").
        public var isKnown: Bool

        public init(account: Account, providerName: String, windows: [QuotaWindow], signInProblem: String?, isKnown: Bool = true) {
            self.account = account
            self.providerName = providerName
            self.windows = windows
            self.signInProblem = signInProblem
            self.isKnown = isKnown
        }
    }

    /// Percentage points below the threshold at which a window without a reset time re-arms.
    public static let rearmMargin: Double = 10

    public static func plan(inputs: [Input], settings: AppSettings, ledger: [String], existingAccountIDs: Set<UUID>,
                            now: Date) -> (alerts: [PendingAlert], ledger: [String]) {
        var kept = prune(ledger, inputs: inputs, settings: settings, existingAccountIDs: existingAccountIDs, now: now)
        var alerts: [PendingAlert] = []
        let subtitle: (Input) -> String = { "\($0.providerName) · \($0.account.name)" }

        if let threshold = settings.quotaAlertThreshold {
            for input in inputs {
                for window in input.windows where !window.isStale(at: now) && window.usedPercent >= Double(threshold) {
                    let key = quotaKey(account: input.account.id, window: window)
                    guard !kept.contains(key) else { continue }
                    kept.append(key)
                    let percent = Int(window.usedPercent.rounded(.down))
                    let body: String
                    if let reset = window.resetsAt {
                        body = "Resets \(ResetPhrase.until(reset, now: now))."
                    } else {
                        body = "TokenBar shows the details in the menu bar."
                    }
                    alerts.append(PendingAlert(id: key, accountID: input.account.id,
                                               title: "\(window.label) quota at \(percent)%",
                                               subtitle: subtitle(input), body: body))
                }
            }
        }

        if settings.signInAlertsEnabled {
            for input in inputs {
                guard let problem = input.signInProblem else { continue }
                let key = signInKey(account: input.account.id)
                guard !kept.contains(key) else { continue }
                kept.append(key)
                alerts.append(PendingAlert(id: key, accountID: input.account.id,
                                           title: "Sign-in needs attention",
                                           subtitle: subtitle(input), body: sentence(problem)))
            }
        }
        return (alerts, kept)
    }

    /// The sign-in problem behind a quota issue, or nil when the issue is not something the user fixes
    /// by signing in (network trouble, server errors, quota turned off).
    public static func signInProblem(for issue: QuotaIssue?) -> String? {
        switch issue {
        case .loginExpired?, .cannotWriteBack?, .accessDenied?: return issue?.message
        default: return nil
        }
    }

    // MARK: Ledger

    static func quotaKey(account: UUID, window: QuotaWindow) -> String {
        let cycle = window.resetsAt.map { String(Int(($0.timeIntervalSince1970 / 3600).rounded())) } ?? "-"
        return "q|\(account.uuidString)|\(window.label)|\(cycle)"
    }

    static func signInKey(account: UUID) -> String { "s|\(account.uuidString)" }

    private static func prune(_ ledger: [String], inputs: [Input], settings: AppSettings,
                              existingAccountIDs: Set<UUID>, now: Date) -> [String] {
        let byAccount = Dictionary(inputs.map { ($0.account.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return ledger.filter { key in
            guard seen.insert(key).inserted else { return false }
            let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, let id = UUID(uuidString: parts[1]), existingAccountIDs.contains(id) else { return false }
            switch parts[0] {
            case "q" where parts.count == 4:
                if parts[3] != "-" {
                    guard let hours = Double(parts[3]) else { return false }
                    return Date(timeIntervalSince1970: hours * 3600) > now
                }
                // No reset time: keep until usage falls clearly below the threshold.
                guard let input = byAccount[parts[1]],
                      let window = input.windows.first(where: { $0.label == parts[2] && $0.resetsAt == nil }) else { return true }
                let threshold = Double(settings.quotaAlertThreshold ?? AppSettings.defaultQuotaAlertThreshold)
                return window.usedPercent >= threshold - rearmMargin
            case "s" where parts.count == 2:
                guard let input = byAccount[parts[1]], input.isKnown else { return true }
                return input.signInProblem != nil
            default:
                return false
            }
        }
    }

    private static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return trimmed }
        return ".?".contains(last) ? trimmed : trimmed + "."
    }
}
