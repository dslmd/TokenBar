import Foundation
import TokenBarCore

/// What the setup window reads from the model. Decisions live in `OnboardingAccounts` (TokenBarCore).
extension AppModel {
    var onboardingGroups: [OnboardingProviderGroup] {
        OnboardingAccounts.groups(catalog: catalog, accounts: accounts, identities: identities) { info in
            let phase = signInPhases[info.id]
            var registered = false
            if case .succeeded(let homePath)? = phase {
                let paths = accounts.filter { $0.providerID == info.id }.map(\.dataPath)
                registered = OnboardingSignInState.isRegistered(homePath: homePath, dataPaths: paths)
            }
            return OnboardingSignInState.make(signIn: info.capabilities.signIn,
                                              unavailableReason: signInUnavailableReason(info.id),
                                              phase: phase,
                                              isWebSignInOpen: isSigningInToMuse,
                                              webSignInMessage: info.id == ProviderCatalog.museAIID ? webSignInMessage : nil,
                                              accountRegistered: registered)
        }
    }

    var onboardingStatus: OnboardingAccountsStatus {
        OnboardingAccounts.status(accountCount: accounts.count, isScanning: isScanning, hasScanned: hasScanned)
    }

    /// Starts a sign-in from the setup window. A web sign-in clears its last error first.
    func startOnboardingSignIn(_ providerID: String) {
        if providerID == ProviderCatalog.museAIID { dismissWebSignInMessage() }
        startSignIn(providerID)
    }

    /// Called when the setup window closes in any way. Nothing is left running out of sight: CLI
    /// sign-ins and the Muse window are cancelled. With notifications on (the default) and macOS not
    /// asked yet, the permission is requested now, so accepting the defaults still gives working alerts.
    func endOnboardingSession() {
        for id in OnboardingSignInState.runningProviders(signInPhases) { cancelSignIn(id) }
        if isSigningInToMuse { cancelMuseSignIn() }
        dismissWebSignInMessage()
        guard !isDemo else { return }
        let notifications = NotificationService.shared
        if OnboardingAlerts.shouldRequestPermission(threshold: settings.quotaAlertThreshold,
                                                    permissionNotDetermined: [.notDetermined, .unknown].contains(notifications.authorization)) {
            notifications.requestAuthorization()
        }
    }
}
