import SwiftUI
import TokenBarCore

/// Snapshots of the settings window, one tab's content per shot (the window toolbar is not part of them).
@MainActor
enum SettingsShots {
    static var all: [SnapshotRunner.Shot] {
        func tab(_ tab: SettingsTab) -> () -> AnyView {
            { AnyView(SettingsTabContent(tab: tab)) }
        }
        func notifications(_ state: NotificationService.Authorization) -> () -> AnyView {
            {
                NotificationService.shared.setAuthorizationForSnapshot(state)
                return AnyView(SettingsTabContent(tab: .notifications))
            }
        }
        // The second Claude Code account (signed in here, sign-in expired), as opened from its detail page.
        let highlighted: () -> AnyView = {
            let id = DemoScenario.rich.state(home: NSHomeDirectory()).config.accounts
                .filter { $0.providerID == "claude" }.dropFirst().first?.id
            return AnyView(SettingsTabContent(tab: .accounts, navigation: SettingsNavigation(highlightedAccountID: id)))
        }
        let catalog = ProviderCatalog.default
        return [
            .init(name: "settings-accounts-rich", scenario: .rich, content: tab(.accounts)),
            .init(name: "settings-accounts-highlight", scenario: .rich, content: highlighted),
            .init(name: "settings-accounts-signing-in", scenario: .signingIn, content: tab(.accounts)),
            .init(name: "settings-accounts-empty", scenario: .empty, content: tab(.accounts)),
            .init(name: "settings-accounts-scanning", scenario: .scanning, content: tab(.accounts)),
            .init(name: "settings-general", scenario: .rich, content: tab(.general)),
            .init(name: "settings-general-quota-metric", scenario: .rich,
                  tweak: { $0.config.settings.menuBarMetric = .peakQuota }, content: tab(.general)),
            .init(name: "settings-general-icon-only", scenario: .rich,
                  tweak: { $0.config.settings.menuBarShowsNumber = false }, content: tab(.general)),
            .init(name: "settings-notifications-not-determined", scenario: .rich, content: notifications(.notDetermined)),
            .init(name: "settings-notifications-denied", scenario: .rich, content: notifications(.denied)),
            .init(name: "settings-notifications-allowed", scenario: .rich, content: notifications(.allowed)),
            .init(name: "settings-notifications-unavailable", scenario: .rich,
                  tweak: { $0.config.settings.quotaAlertThreshold = nil }, content: notifications(.unavailable)),
            .init(name: "settings-sheet-rename", scenario: .rich, content: {
                AnyView(SettingsRenameSheet(currentName: "alex@example.com") { _ in })
            }),
            .init(name: "settings-sheet-add-folder", scenario: .rich, content: {
                AnyView(SettingsAddFolderSheet(provider: catalog.info(for: "claude") ?? ProviderCatalog.museAI) {})
            }),
        ]
    }
}
