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
