import SwiftUI
import TokenBarCore

/// Snapshots of the menu bar window and the menu bar label.
@MainActor
enum PopoverShots {
    static var all: [SnapshotRunner.Shot] {
        let popover: () -> AnyView = { AnyView(PopoverView()) }
        let menuBar: () -> AnyView = { AnyView(MenuBarSnapshot()) }
        return [
            .init(name: "popover-rich", scenario: .rich, menuBarWindow: true, content: popover),
            .init(name: "popover-rich-collapsed", scenario: .rich, collapsed: "claude,codex", menuBarWindow: true, content: popover),
            .init(name: "popover-sparse", scenario: .sparse, menuBarWindow: true, content: popover),
            .init(name: "popover-empty", scenario: .empty, menuBarWindow: true, content: popover),
            .init(name: "popover-scanning", scenario: .scanning, menuBarWindow: true, content: popover),
            .init(name: "popover-all-off", scenario: .allOff, menuBarWindow: true, content: popover),
            .init(name: "popover-loading", scenario: .loading, menuBarWindow: true, content: popover),
            .init(name: "menubar-rich", scenario: .rich, content: menuBar),
            .init(name: "menubar-sparse", scenario: .sparse, content: menuBar),
            .init(name: "menubar-empty", scenario: .empty, content: menuBar),
        ]
    }
}

/// The menu bar label on a plain strip, at the menu bar's text size.
struct MenuBarSnapshot: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        MenuBarLabel(model: model)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 24)
    }
}
