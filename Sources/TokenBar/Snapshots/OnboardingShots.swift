import SwiftUI
import TokenBarCore

/// Snapshots of the first-launch setup window.
@MainActor
enum OnboardingShots {
    static var all: [SnapshotRunner.Shot] {
        [
            .init(name: "onboarding-welcome", scenario: .rich, content: { AnyView(OnboardingView()) }),
        ]
    }
}
