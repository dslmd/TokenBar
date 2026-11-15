import SwiftUI
import TokenBarCore

/// Shared tokens of the menu bar window (SPEC section 3).
enum PopoverStyle {
    static let width: CGFloat = 340
    static let maxScrollHeight: CGFloat = 520
    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 12
    static let groupRadius: CGFloat = 10
    static let groupFill = Color.primary.opacity(0.05)
    static let hoverFill = Color.primary.opacity(0.08)
    static let pressedFill = Color.primary.opacity(0.12)
    static let trackFill = Color.primary.opacity(0.1)
    /// How often relative times ("2 min ago") are worked out again while the window is open.
    static let clockInterval: TimeInterval = 30

    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.2)
    }

    /// Bar and dot color for a quota level: accent, orange, red, gray.
    static func tint(_ level: QuotaLevel) -> Color {
        switch level {
        case .normal: return .accentColor
        case .elevated: return .orange
        case .critical: return .red
        case .stale: return .gray
        }
    }

    /// Color for a percentage in text: only elevated and critical stand out.
    static func textTint(_ level: QuotaLevel) -> Color? {
        switch level {
        case .elevated: return .orange
        case .critical: return .red
        case .normal, .stale: return nil
        }
    }
}

/// A rounded group fill, as in grouped lists. Never covers the whole window (the window is translucent).
struct PopoverGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: PopoverStyle.groupRadius, style: .continuous).fill(PopoverStyle.groupFill))
            .clipShape(RoundedRectangle(cornerRadius: PopoverStyle.groupRadius, style: .continuous))
    }
}

/// Small section title: optional SF Symbol, name, optional trailing value.
struct PopoverSectionLabel: View {
    let title: String
    var systemImage: String?
    var trailing: String?
    /// Leading inset: a little over a group, none over free content.
    var inset: CGFloat = 4

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(title)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing).fontWeight(.regular).monospacedDigit()
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, inset)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A horizontal capsule bar, `fraction` 0...1.
struct PopoverBar: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = 5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(PopoverStyle.trackFill)
                if fraction > 0 {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(height, geo.size.width * CGFloat(min(1, fraction))))
                        .animation(PopoverStyle.animation(reduceMotion: reduceMotion), value: fraction)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// "Weekly 93% · resets in 2 days" with only the percentage tinted.
struct QuotaSummaryText: View {
    let summary: QuotaSummary

    var body: some View {
        let percent = Text(summary.percentText).fontWeight(.medium)
        let tinted = PopoverStyle.textTint(summary.level).map { percent.foregroundColor($0) } ?? percent
        let rest = summary.resetPhrase.map { Text(" · \($0)") } ?? Text("")
        return (Text("\(summary.label) ") + tinted + rest)
            .monospacedDigit()
            .lineLimit(1)
    }
}

/// One quota window on the detail page: label, reset note, percentage and a 5 pt bar.
struct QuotaBar: View {
    let window: QuotaWindow
    var now = Date()

    var body: some View {
        let summary = QuotaSummary(window: window, now: now)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(summary.label).font(.callout)
                Spacer(minLength: 6)
                if let note = summary.detailNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                if summary.level != .stale {
                    Text(summary.percentText)
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                        .foregroundColor(PopoverStyle.textTint(summary.level))
                        .frame(minWidth: 34, alignment: .trailing)
                }
            }
            PopoverBar(fraction: summary.fraction, tint: PopoverStyle.tint(summary.level))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.level == .stale
                            ? "\(summary.label), window reset, updates after use"
                            : "\(summary.label) \(summary.percentText) used" + (summary.resetPhrase.map { ", \($0)" } ?? ""))
    }
}

/// A short secondary line with an icon.
struct StatusLine: View {
    let systemImage: String
    let text: String
    var iconColor: Color?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: systemImage)
                .foregroundColor(iconColor)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

/// A problem the user has to act on, always ending as a sentence.
struct AttentionLine: View {
    let text: String
    var lineLimit: Int? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .accessibilityLabel("Warning")
            Text(PopoverText.sentence(text))
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: lineLimit == nil)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

/// "Reading…" with a small spinner.
struct ReadingLine: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text("Reading…")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// A number with a caption, in a small group: Today / Last 7 days / This month.
struct StatTile: View {
    let title: String
    let value: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value.map(Fmt.tokens) ?? "–")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: PopoverStyle.groupRadius, style: .continuous).fill(PopoverStyle.groupFill))
        .help(value.map { "\(TokenFormatter.grouped($0)) tokens" } ?? "Not read yet")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value.map { "\(Fmt.tokens($0)) tokens" } ?? "not read yet")")
    }
}

/// Input / output / cache split as a 5 pt bar with a text legend (never color only).
struct SplitBar: View {
    let tokens: TokenBreakdown
    /// Shown before the legend, e.g. "Today".
    var title: String?

    private var parts: [(name: String, value: Int, color: Color)] {
        [("Input", tokens.input, Color.accentColor),
         ("Output", tokens.output, Color.accentColor.opacity(0.5)),
         ("Cache", tokens.cache, Color.primary.opacity(0.22))]
    }

    var body: some View {
        let total = max(1, parts.reduce(0) { $0 + $1.value })
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    ForEach(parts.indices, id: \.self) { i in
                        if parts[i].value > 0 {
                            Rectangle()
                                .fill(parts[i].color)
                                .frame(width: max(2, (geo.size.width - 3) * CGFloat(parts[i].value) / CGFloat(total)))
                        }
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 5)
            HStack(spacing: 10) {
                if let title {
                    Text(title).fontWeight(.medium)
                }
                ForEach(parts.indices, id: \.self) { i in
                    HStack(spacing: 4) {
                        Circle().fill(parts[i].color).frame(width: 6, height: 6)
                        Text("\(parts[i].name) \(Fmt.tokens(parts[i].value))").monospacedDigit()
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .help("Cache read \(TokenFormatter.grouped(tokens.cacheRead)), cache write \(TokenFormatter.grouped(tokens.cacheWrite))")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([title].compactMap { $0 } + parts.map { "\($0.name) \(Fmt.tokens($0.value))" }).joined(separator: ", "))
    }
}

/// Seven daily columns, today in accent and the others lighter, with a help tag per column.
struct DailyBars: View {
    let days: [DailyUsage]
    let value: (TokenBreakdown) -> Int
    var height: CGFloat = 64
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let values = days.map { value($0.tokens) }
        let peak = max(1, values.max() ?? 1)
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(days.indices, id: \.self) { index in
                let isToday = index == days.count - 1
                VStack(spacing: 4) {
                    ZStack(alignment: .bottom) {
                        Color.clear.frame(height: height)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(values[index] == 0 ? PopoverStyle.trackFill : Color.accentColor.opacity(isToday ? 1 : 0.35))
                            .frame(height: max(2, height * CGFloat(values[index]) / CGFloat(peak)))
                            .animation(PopoverStyle.animation(reduceMotion: reduceMotion), value: values[index])
                    }
                    Text(Fmt.weekdayInitial(days[index].day))
                        .font(.caption2.weight(isToday ? .semibold : .regular))
                        .foregroundStyle(isToday ? .primary : .secondary)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .help("\(Fmt.dayMonth(days[index].day)): \(TokenFormatter.grouped(values[index])) tokens")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Fmt.dayMonth(days[index].day)), \(Fmt.tokens(values[index])) tokens")
            }
        }
    }
}

/// Row highlight on hover and press, for rows that are buttons.
struct PopoverRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(configuration.isPressed ? PopoverStyle.pressedFill : (hovering ? PopoverStyle.hoverFill : Color.clear))
                .onHover { hovering = $0 }
        }
    }
}

/// Gives its single child (a scroll view) the height of the child's content, up to `cap`, whatever
/// height it is offered. The menu bar window sizes itself to its content offered no room at all, and a
/// plain scroll view then shrinks to nothing, so the content would disappear.
struct PopoverScrollHeight: Layout {
    let cap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = proposal.width.flatMap { $0 > 0 ? $0 : nil }
        let content = child.sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width ?? content.width, height: min(content.height, cap))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
