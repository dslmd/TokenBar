import SwiftUI
import AppKit
import TokenBarCore

/// Process entry point. `TokenBar --snapshot <output-dir>` renders the UI with demo data to PNG files and
/// exits (see `SnapshotRunner`); anything else starts the menu bar app (`--demo [scenario]` starts it on
/// demo data, see `AppModel.forLaunch`).
@main
enum TokenBarMain {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        // Development aid: prints how reading usage from muse.ai goes for each Muse account, structure only
        // (statuses, matched patterns, key names). Never prints cookies or response values.
        if arguments.contains("--diagnose-muse") {
            exit(MuseDiagnosticsRunner.run())
        }
        if let flag = arguments.firstIndex(of: "--snapshot") {
            let directory = flag + 1 < arguments.count ? arguments[flag + 1] : "snapshots"
            exit(SnapshotRunner.run(outputDirectory: directory, arguments: arguments))
        }
        TokenBarApp.main()
    }
}

struct TokenBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.forLaunch()

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Keeps the app out of the Dock (Info.plist also sets LSUIElement).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // The model is created with the first scene; wait a moment for it.
        DispatchQueue.main.async {
            guard let model = AppModel.current else { return }
            let notifications = NotificationService.shared
            notifications.refreshAuthorization()
            model.deliverAlerts = { notifications.deliver($0) }
            if model.needsOnboarding {
                OnboardingWindowController.shared.show(model: model)
            }
            let arguments = CommandLine.arguments
            // Development aids for checking real windows: --onboarding, --settings [general|accounts|notifications].
            if arguments.contains("--onboarding") {
                OnboardingWindowController.shared.show(model: model)
            }
            if let flag = arguments.firstIndex(of: "--settings") {
                let name = flag + 1 < arguments.count ? arguments[flag + 1] : ""
                SettingsWindowController.shared.show(model: model, tab: SettingsTab(rawValue: name) ?? .general)
            }
            // Development aid: shows example notifications built from the current data
            // (works from the app bundle only, e.g. open build/TokenBar.app --args --demo --sample-notifications).
            if arguments.contains("--sample-notifications") {
                notifications.requestAuthorization { _ in notifications.deliver(model.sampleAlerts()) }
            }
        }
    }

    /// Sign-ins still running would leave CLI processes behind; stop them before quitting.
    func applicationWillTerminate(_ notification: Notification) {
        AppModel.current?.prepareForTermination()
    }
}

@MainActor
enum MuseDiagnosticsRunner {
    static func run() -> Int32 {
        guard let config = ConfigStore().load() else { print("No TokenBar config found."); return 1 }
        let museAccounts = config.accounts.filter { $0.providerID == ProviderCatalog.museAIID }
        if museAccounts.isEmpty { print("No Muse accounts."); return 1 }
        let secrets = KeychainSecretStore()
        let cached = MuseAIUserDefaultsStore().string(forKey: MuseAIFetcher.actionIDKey)
        var done = false
        Task {
            for account in museAccounts {
                print("== Muse account \(account.id.uuidString.prefix(8))")
                guard let secret = secrets.secret(for: account.id), let cookies = MuseAICookieSet(serialized: secret) else {
                    print("no stored session"); continue
                }
                for line in await MuseAIDiagnostics.run(cookies: cookies, cachedActionID: cached) { print(line) }
            }
            done = true
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        return 0
    }
}
