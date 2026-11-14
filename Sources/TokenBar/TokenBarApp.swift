import SwiftUI
import AppKit
import TokenBarCore

@main
struct TokenBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

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
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
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
