import Foundation

/// Tracks "Sign in to another account" attempts per provider on top of an `AccountLoginDriving`.
///
/// Phases from the driver may arrive on any thread; they are hopped to the main actor here. Phases from an
/// attempt that was cancelled or replaced are ignored, so a late callback cannot resurrect an old attempt.
@MainActor
public final class SignInSessions {
    public private(set) var phases: [String: LoginPhase] = [:]
    /// Called after every phase change.
    public var onChange: (() -> Void)?
    /// Called once per successful sign-in with the provider id and the managed home path.
    public var onSuccess: ((_ providerID: String, _ homePath: String) -> Void)?

    public let driver: AccountLoginDriving
    private var handles: [String: LoginHandle] = [:]
    private var attempts: [String: UUID] = [:]

    public init(driver: AccountLoginDriving) {
        self.driver = driver
    }

    public func unavailableReason(providerID: String) -> String? {
        driver.unavailableReason(providerID: providerID)
    }

    public func isRunning(_ providerID: String) -> Bool {
        guard let phase = phases[providerID] else { return false }
        return !Self.isFinal(phase)
    }

    public func start(_ providerID: String) {
        if isRunning(providerID) { handles[providerID]?.cancel() }
        let attempt = UUID()
        attempts[providerID] = attempt
        phases[providerID] = .locatingCLI
        onChange?()
        let handle = driver.start(providerID: providerID) { [weak self] phase in
            Task { @MainActor in self?.receive(phase, providerID: providerID, attempt: attempt) }
        }
        // The driver may already have finished synchronously; only keep the handle for a live attempt.
        if attempts[providerID] == attempt { handles[providerID] = handle }
    }

    public func cancel(_ providerID: String) {
        guard isRunning(providerID) else { return }
        attempts[providerID] = nil
        handles.removeValue(forKey: providerID)?.cancel()
        phases[providerID] = .cancelled
        onChange?()
    }

    /// Clears a finished attempt's message.
    public func dismiss(_ providerID: String) {
        guard !isRunning(providerID) else { return }
        phases[providerID] = nil
        onChange?()
    }

    public func cancelAll() {
        for id in Array(phases.keys) { cancel(id) }
    }

    func receive(_ phase: LoginPhase, providerID: String, attempt: UUID) {
        guard attempts[providerID] == attempt else { return }
        phases[providerID] = phase
        if Self.isFinal(phase) {
            attempts[providerID] = nil
            handles[providerID] = nil
        }
        if case .succeeded(let home) = phase { onSuccess?(providerID, home) }
        onChange?()
    }

    public static func isFinal(_ phase: LoginPhase) -> Bool {
        switch phase {
        case .succeeded, .failed, .cancelled: return true
        case .locatingCLI, .waitingForUser: return false
        }
    }

    /// The managed home to delete when the user removes an account, or nil when the account is not a
    /// TokenBar-managed sign-in (detected and manual accounts are never deleted from disk).
    public nonisolated static func managedHomeToRemove(for account: Account, driver: AccountLoginDriving, home: String) -> String? {
        guard account.origin == .signedIn, !account.dataPath.isEmpty else { return nil }
        let path = normalizedPath(account.dataPath, home: home)
        var candidates = [path]
        if let suffix = ProviderHomeRule.rule(for: account.providerID)?.managedSuffix, !suffix.isEmpty, path.hasSuffix(suffix) {
            candidates.insert(String(path.dropLast(suffix.count)), at: 0)
        }
        return candidates.first { driver.isManagedHome($0) }
    }
}

/// Coarse status for the dot next to an account in settings.
public enum AccountHealth: Equatable, Sendable {
    case ok, warning, error, disabled, unknown

    public static func evaluate(account: Account, usage: AccountUsage?, quota: QuotaResult?) -> (AccountHealth, String) {
        guard account.isEnabled else { return (.disabled, "Turned off") }
        guard let usage else { return (.unknown, "Not read yet") }
        switch usage.status {
        case .unknownProvider: return (.error, "Unknown provider")
        case .dataDirectoryMissing: return (.error, "Folder not found")
        case .ok, .noRecentData: break
        }
        if let issue = quota?.issue, issue != .disabled, issue != .unsupported {
            return (.warning, issue.message)
        }
        return (.ok, usage.status == .noRecentData ? "No usage this month" : "Working")
    }
}
