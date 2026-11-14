import Foundation

/// App-facing decisions for Muse (muse.ai) accounts, kept here so they are testable.
public enum MuseAIAccounts {
    /// Default name for a newly signed-in account: the account label when known, else "Muse <plan>", else "Muse".
    /// A name already used by another account gets " 2", " 3", ... appended.
    public static func defaultName(accountLabel: String?, planName: String?, existingNames: [String]) -> String {
        let base: String
        if let label = accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            base = label
        } else if let plan = planName?.trimmingCharacters(in: .whitespacesAndNewlines), !plan.isEmpty {
            // "Muse Free" is already a full name; "Power" becomes "Muse Power".
            base = plan.lowercased().hasPrefix("muse") ? plan : "Muse \(plan)"
        } else {
            base = "Muse"
        }
        let taken = Set(existingNames.map { $0.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    /// Status for the dot in settings and the line under it.
    public static func health(account: Account, state: MuseAIService.State?, onlineQuotaEnabled: Bool) -> (AccountHealth, String) {
        guard account.isEnabled else { return (.disabled, "Turned off") }
        guard onlineQuotaEnabled, account.onlineQuotaEnabled else { return (.unknown, "Online quota is off, so Muse usage is not read") }
        guard let state else { return (.unknown, "Not read yet") }
        if let failure = state.failure {
            switch failure {
            case .signedOut, .sessionExpired: return (.error, failure.message)
            case .siteChanged, .network, .server: return (.warning, failure.message)
            }
        }
        return state.usage == nil ? (.unknown, "Not read yet") : (.ok, "Working")
    }

    /// True when the account should offer "Sign in again".
    public static func needsSignIn(_ state: MuseAIService.State?) -> Bool {
        state?.failure?.needsSignIn == true
    }

    /// Online quota results for the menu bar warning (only accounts with a successful read).
    public static func quotaResults(_ states: [UUID: MuseAIService.State]) -> [UUID: QuotaResult] {
        states.compactMapValues { s in s.usage.map { QuotaResult(observation: $0.quotaObservation) } }
    }
}

public extension MuseAIUsage {
    /// "Additional tokens: 1.5B tokens left", or nil without a top-up.
    var topUpText: String? {
        topUp.map { "\($0.label): \($0.value)" }
    }

    /// Secondary lines under the quota bar: tokens left and the top-up, when present.
    var detailLines: [String] {
        [tokensLeft, topUpText].compactMap { $0 }
    }
}
