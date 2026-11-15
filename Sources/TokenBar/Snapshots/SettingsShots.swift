import SwiftUI
import TokenBarCore

/// Snapshots of the settings window.
@MainActor
enum SettingsShots {
    static var all: [SnapshotRunner.Shot] {
        let settings: () -> AnyView = { AnyView(SettingsView()) }
        return [
            .init(name: "settings-accounts-rich", scenario: .rich, content: settings),
            .init(name: "settings-accounts-signing-in", scenario: .signingIn, content: settings),
            .init(name: "settings-accounts-empty", scenario: .empty, content: settings),
            .init(name: "settings-general-rich", scenario: .rich, tabIndex: 1, content: settings),
        ]
    }
}
