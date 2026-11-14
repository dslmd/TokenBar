import Foundation

/// Progress of one "sign in to another account" attempt.
public enum LoginPhase: Equatable, Sendable {
    case locatingCLI
    /// The CLI is running and waiting for the user (browser or Terminal). `hint` is a short English sentence for the UI.
    case waitingForUser(hint: String)
    /// Credentials appeared. `homePath` is the managed home directory to register as an account.
    case succeeded(homePath: String)
    /// `message` is a short English sentence for the UI (e.g. CLI not installed, with the install command).
    case failed(message: String)
    case cancelled
}

public protocol LoginHandle: Sendable {
    func cancel()
}

/// Adds accounts by delegating to each official CLI's own sign-in inside a TokenBar-managed home directory.
public protocol AccountLoginDriving: Sendable {
    /// Nil when sign-in is available for this provider; otherwise a short English reason to show instead of the button.
    func unavailableReason(providerID: String) -> String?
    /// Starts a sign-in. `onPhase` may be called on any thread, several times, ending with succeeded, failed or cancelled.
    func start(providerID: String, onPhase: @escaping @Sendable (LoginPhase) -> Void) -> LoginHandle
    /// Shell alias that runs the CLI with this managed home, or nil if not applicable.
    func shellAlias(providerID: String, homePath: String) -> String?
    /// Deletes a managed home directory (only paths under the managed root; no-op otherwise).
    func removeManagedHome(at homePath: String)
    /// Whether `path` is inside the managed root.
    func isManagedHome(_ path: String) -> Bool
}
