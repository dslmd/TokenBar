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
    }

    /// Sign-ins still running would leave CLI processes behind; stop them before quitting.
    func applicationWillTerminate(_ notification: Notification) {
        AppModel.current?.prepareForTermination()
    }
}

/// Template SF Symbol (adapts to the menu bar appearance) plus an optional number.
/// The symbol switches to a warning triangle when any quota window is above 90 %.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: model.menuBarSymbol)
            if model.settings.menuBarShowsNumber {
                Text(model.menuBarTitle).monospacedDigit()
            }
        }
        .accessibilityLabel(model.menuBarWarning ? "TokenBar, quota almost used up, \(model.menuBarTitle)" : "TokenBar, \(model.menuBarTitle)")
    }
}
