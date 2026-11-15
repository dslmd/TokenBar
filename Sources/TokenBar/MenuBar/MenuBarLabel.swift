import SwiftUI
import TokenBarCore

/// Template SF Symbol (adapts to the menu bar appearance) plus an optional number: today's tokens or the
/// highest quota, as set in settings. The symbol turns into a warning triangle when any current quota
/// window is at 90 % or more.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let content = MenuBarLabelContent(title: model.menuBarTitle, showsNumber: model.settings.menuBarShowsNumber,
                                          warning: model.menuBarWarning, metric: model.settings.menuBarMetric,
                                          period: model.settings.menuBarPeriod)
        HStack(spacing: 4) {
            Image(systemName: content.symbolName)
                .renderingMode(.template)
            if let text = content.text {
                Text(text).monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.accessibilityLabel)
    }
}
