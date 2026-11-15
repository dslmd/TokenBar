import SwiftUI
import AppKit
import TokenBarCore

enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

enum FolderPicker {
    @MainActor
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct StatusDot: View {
    let health: AccountHealth

    private var color: Color {
        // A problem is orange, the same as the problem line under the row.
        switch SettingsRules.statusTone(health) {
        case .ok: return .green
        case .problem: return .orange
        case .inactive: return Color(nsColor: .tertiaryLabelColor)
        }
    }

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
}

/// The `…` button that opens a row's or a section's menu.
struct SettingsMoreMenu<Content: View>: View {
    let accessibilityLabel: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu(content: content) {
            Image(systemName: "ellipsis.circle")
                .imageScale(.large)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// A small orange warning line under a row.
struct SettingsProblemText: View {
    let text: String

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .labelStyle(SettingsLabelStyle())
    }
}

/// Icon and title close together, aligned on the first line of text.
struct SettingsLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

/// Explanation under a form section, aligned with the section's leading edge.
struct SettingsFooter: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsFooter.inset)
    }

    /// Lines footers up with the rows' text (grouped forms place footers at the box edge).
    static let inset: CGFloat = 10
}
