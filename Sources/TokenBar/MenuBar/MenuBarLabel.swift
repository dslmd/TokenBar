import SwiftUI
import TokenBarCore

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
