import SwiftUI
import TokenBarCore

/// Snapshots of the first-launch setup window, one per page plus the states of the accounts page.
@MainActor
enum OnboardingShots {
    static var all: [SnapshotRunner.Shot] {
        /// The notification permission is fixed per shot so the images do not depend on this Mac.
        func page(_ page: OnboardingPage, notifications: NotificationService.Authorization = .notDetermined) -> () -> AnyView {
            {
                NotificationService.shared.setAuthorizationForSnapshot(notifications)
                return AnyView(OnboardingView(startPage: page))
            }
        }
        return [
            .init(name: "onboarding-welcome", scenario: .rich, content: page(.welcome)),
            .init(name: "onboarding-accounts-rich", scenario: .rich, content: page(.accounts)),
            .init(name: "onboarding-accounts-empty", scenario: .empty, content: page(.accounts)),
            .init(name: "onboarding-accounts-scanning", scenario: .scanning, content: page(.accounts)),
            .init(name: "onboarding-accounts-sparse-scanning", scenario: .sparse, tweak: { $0.isScanning = true },
                  content: page(.accounts)),
            .init(name: "onboarding-accounts-signing-in", scenario: .signingIn, content: page(.accounts)),
            // A CLI sign-in finished; its account is not listed yet.
            .init(name: "onboarding-accounts-signed-in", scenario: .sparse, tweak: { state in
                state.signInPhases = ["codex": .succeeded(homePath: "/tmp/tokenbar-demo/accounts/codex-new")]
            }, content: page(.accounts)),
            // The Claude installer command is the longest one.
            .init(name: "onboarding-accounts-claude-missing", scenario: .empty, tweak: { state in
                state.signInPhases = ["claude": .failed(message: "Claude Code is not installed. Install it with: curl -fsSL https://claude.ai/install.sh | bash")]
            }, content: page(.accounts)),
            .init(name: "onboarding-accounts-turned-off", scenario: .sparse, tweak: { state in
                for i in state.config.accounts.indices { state.config.accounts[i].isEnabled = false }
            }, content: page(.accounts)),
            .init(name: "onboarding-alerts-rich", scenario: .rich, content: page(.alerts)),
            .init(name: "onboarding-alerts-off", scenario: .rich, tweak: { state in
                state.config.settings.onlineQuotaEnabled = false
                state.config.settings.quotaAlertThreshold = nil
            }, content: page(.alerts)),
            .init(name: "onboarding-alerts-denied", scenario: .rich, content: page(.alerts, notifications: .denied)),
            .init(name: "onboarding-alerts-allowed", scenario: .rich, content: page(.alerts, notifications: .allowed)),
            .init(name: "onboarding-alerts-unavailable", scenario: .rich, content: page(.alerts, notifications: .unavailable)),
        ]
    }
}
