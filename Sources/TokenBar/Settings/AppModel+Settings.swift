import TokenBarCore

extension AppModel {
    /// Whether a CLI sign-in for this provider is in progress (locating the CLI or waiting for the user).
    func isSigningIn(_ providerID: String) -> Bool {
        switch signInPhases[providerID] {
        case .locatingCLI?, .waitingForUser?: return true
        default: return false
        }
    }
}
