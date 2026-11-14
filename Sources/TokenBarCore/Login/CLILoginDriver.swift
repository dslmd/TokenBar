import Foundation

// TEMPORARY PLACEHOLDER. The real CLILoginDriver is built separately and replaces this file at merge.
// Every provider reports sign-in as unavailable and `start` fails immediately.
public final class CLILoginDriver: AccountLoginDriving {
    private struct NoopHandle: LoginHandle {
        func cancel() {}
    }

    public init(managedRoot: URL) {}

    public func unavailableReason(providerID: String) -> String? { "Sign-in is not available yet" }

    public func start(providerID: String, onPhase: @escaping @Sendable (LoginPhase) -> Void) -> LoginHandle {
        onPhase(.failed(message: "Sign-in is not available yet"))
        return NoopHandle()
    }

    public func shellAlias(providerID: String, homePath: String) -> String? { nil }

    public func removeManagedHome(at homePath: String) {}

    public func isManagedHome(_ path: String) -> Bool { false }
}
