import Foundation

/// Decisions behind the settings window, kept out of the views so they can be tested.
public enum SettingsRules {
    // MARK: Account rows

    /// The line under an account's name: what is known about the sign-in, without repeating the name.
    /// For example "Max · Example Labs" for an account named after its email, or
    /// "alex@example.com · Plus" for an account the user renamed to "Work".
    /// - Parameters:
    ///   - identity: what the CLI's own files say (nil for providers without local files).
    ///   - webPlan: the plan read online (Muse), used when there is no local identity.
    ///   - origin: used when nothing else is known, so the row still says where the account came from.
    public static func accountSubtitle(name: String, identity: AccountIdentity?, webPlan: String? = nil,
                                       origin: AccountOrigin? = nil) -> String? {
        var parts: [String] = []
        if let identity {
            if let email = identity.email?.trimmingCharacters(in: .whitespaces), !email.isEmpty,
               email.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) != .orderedSame {
                parts.append(email)
            }
            if let plan = identity.planLabel { parts.append(plan) }
            if let org = identity.organization?.trimmingCharacters(in: .whitespaces), !org.isEmpty,
               org.caseInsensitiveCompare(name) != .orderedSame {
                parts.append(org)
            }
            if parts.isEmpty && identity.isSignedIn && identity.email == nil { parts.append("Signed in") }
        }
        if parts.isEmpty, let plan = webPlan?.trimmingCharacters(in: .whitespaces), !plan.isEmpty {
            parts.append(plan.lowercased().hasSuffix("plan") ? plan : "\(plan) plan")
        }
        if parts.isEmpty, let origin { parts.append(origin.label) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The help tag on an account row: where the account came from and, for folder accounts, its folder.
    public static func accountHelp(origin: AccountOrigin?, path: String?, home: String) -> String {
        let source = (origin ?? .manual).label
        guard let path, !path.isEmpty else { return source }
        return "\(source) · \(shortPath(path, home: home))"
    }

    /// Home-relative spelling of a path, e.g. "~/.claude-work".
    public static func shortPath(_ path: String, home: String) -> String {
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// A name typed into the rename sheet, cleaned up; nil when it cannot be used (empty, or unchanged).
    public static func validatedName(_ typed: String, current: String) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != current else { return nil }
        return String(trimmed.prefix(80))
    }

    /// How the status dot and the problem line are colored. Every problem (a warning or an error) shares
    /// one tone, so the dot and the orange line under the row always agree.
    public enum StatusTone: Equatable, Sendable {
        case ok, problem, inactive
    }

    public static func statusTone(_ health: AccountHealth) -> StatusTone {
        switch health {
        case .ok: return .ok
        case .warning, .error: return .problem
        case .disabled, .unknown: return .inactive
        }
    }

    /// Whether a provider section shows the grey "No accounts yet" row. Not while a scan runs (TokenBar does
    /// not know yet), and not when a button to add an account follows (its title already says there are none).
    public static func showsNoAccountsRow(accountCount: Int, hasScanned: Bool, isScanning: Bool,
                                          hasAddButton: Bool) -> Bool {
        accountCount == 0 && hasScanned && !isScanning && !hasAddButton
    }

    /// A sign-in failure split into its sentence and, when it ends with one, a command to copy.
    /// "Gemini CLI is not installed. Install it with: npm install -g @google/gemini-cli" gives the sentence
    /// "Gemini CLI is not installed. Install it with:" and the command "npm install -g @google/gemini-cli".
    public struct SignInFailureText: Equatable, Sendable {
        public let sentence: String
        public let command: String?
    }

    public static func signInFailureText(_ message: String) -> SignInFailureText {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator = trimmed.range(of: ":\n") ?? trimmed.range(of: ": ")
        guard let separator else { return SignInFailureText(sentence: trimmed, command: nil) }
        let head = String(trimmed[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
        let tail = String(trimmed[separator.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        // A command is one line that does not read like a sentence.
        let looksLikeCommand = !head.isEmpty && !tail.isEmpty && !tail.contains("\n")
            && !tail.hasSuffix(".") && !tail.contains(". ") && tail.first.map { !$0.isUppercase } == true
        guard looksLikeCommand else { return SignInFailureText(sentence: trimmed, command: nil) }
        return SignInFailureText(sentence: head + ":", command: tail)
    }

    // MARK: General

    /// Period and cache only change the number when the menu bar shows tokens.
    public static func tokenOptionsApply(_ metric: MenuBarMetric) -> Bool { metric == .tokens }

    /// Period and cache are only worth changing when the number is shown and it counts tokens.
    public static func tokenOptionsApply(_ metric: MenuBarMetric, showsNumber: Bool) -> Bool {
        showsNumber && tokenOptionsApply(metric)
    }

    public static func metricTitle(_ metric: MenuBarMetric) -> String {
        switch metric {
        case .tokens: return "Tokens"
        case .peakQuota: return "Highest quota"
        }
    }

    /// Refresh intervals offered in settings, in seconds. A stored value not in the list is kept and offered too.
    public static func refreshChoices(current: Int) -> [Int] {
        let standard = [15, 30, 60, 120, 300]
        return standard.contains(current) ? standard : (standard + [current]).sorted()
    }

    public static func refreshTitle(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) seconds" }
        if seconds % 60 == 0 { return seconds == 60 ? "1 minute" : "\(seconds / 60) minutes" }
        return "\(seconds) seconds"
    }

    // MARK: Notifications

    /// Whether quota notifications are on.
    public static func quotaAlertsOn(_ threshold: Int?) -> Bool { threshold != nil }

    /// The threshold the picker shows: the stored one, or the default while notifications are off.
    /// A stored value that is not one of the choices snaps to the nearest choice.
    public static func thresholdPickerValue(_ threshold: Int?) -> Int {
        let choices = AppSettings.quotaAlertThresholdChoices
        guard let threshold else { return AppSettings.defaultQuotaAlertThreshold }
        if choices.contains(threshold) { return threshold }
        return choices.min { abs($0 - threshold) < abs($1 - threshold) } ?? AppSettings.defaultQuotaAlertThreshold
    }

    /// The new stored threshold after the switch is flipped.
    public static func threshold(afterToggle on: Bool, current: Int?) -> Int? {
        on ? thresholdPickerValue(current) : nil
    }

    /// Turning a notification switch on is the moment to ask for permission, but only when the system has
    /// not asked yet (it never shows its prompt twice).
    public static func shouldAskForPermission(turningOn: Bool, permissionNotDetermined: Bool) -> Bool {
        turningOn && permissionNotDetermined
    }

    // MARK: Window

    /// The content height of a settings tab: its ideal height within sensible window limits.
    public static func windowContentHeight(ideal: Double, minimum: Double = 240, maximum: Double = 640) -> Double {
        guard ideal.isFinite, ideal > 0 else { return minimum }
        return min(maximum, max(minimum, ideal.rounded(.up)))
    }
}
