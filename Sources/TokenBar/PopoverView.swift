import SwiftUI
import AppKit
import TokenBarCore

struct PopoverView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Comma separated provider ids whose section is collapsed (remembered across launches).
    @AppStorage("collapsedProviders") private var collapsedRaw = ""

    private var collapsed: Set<String> {
        Set(collapsedRaw.split(separator: ",").map { String($0) })
    }

    private func toggle(_ id: String) {
        var set = collapsed
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        collapsedRaw = set.sorted().joined(separator: ",")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.accounts.isEmpty {
                EmptyState()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(model.registry.providers, id: \.id) { provider in
                            let accounts = model.accounts(for: provider.id)
                            if !accounts.isEmpty {
                                ProviderSection(
                                    provider: provider,
                                    accounts: accounts,
                                    isCollapsed: collapsed.contains(provider.id),
                                    onToggle: {
                                        withAnimation(reduceMotion ? nil : Animation.easeInOut(duration: 0.2)) { toggle(provider.id) }
                                    })
                            }
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 520)
            }
            Divider()
            footer
        }
        .frame(width: 380)
        .onAppear { model.refreshIfStale() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar.fill")
                .foregroundStyle(Color.accentColor)
            Text("TokenBar").font(.headline)
            Spacer()
            if model.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await model.refresh(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("r")
            .help("立即刷新（⌘R）")
            .accessibilityLabel("立即刷新")
            .disabled(model.isRefreshing)

            Button {
                SettingsWindowController.shared.show(model: model)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(",")
            .help("设置（⌘,）")
            .accessibilityLabel("设置")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            if let last = model.lastRefresh {
                Text("更新于 \(Fmt.clockTime(last))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("正在读取…").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("退出") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
                .help("退出 TokenBar（⌘Q）")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct EmptyState: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("还没有账户").font(.headline)
            Text("在设置中添加 Codex、Claude Code、Gemini CLI 或 Muse Code 的数据目录。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("打开设置") { SettingsWindowController.shared.show(model: model) }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

struct ProviderSection: View {
    @EnvironmentObject var model: AppModel
    let provider: any UsageProvider
    let accounts: [Account]
    let isCollapsed: Bool
    let onToggle: () -> Void

    private var todayTotal: Int {
        accounts.compactMap { model.usage[$0.id] }.reduce(0) { $0 + model.displayTotal($1.today) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .frame(width: 12)
                    Label(provider.displayName, systemImage: provider.symbolName)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("今日 \(Fmt.tokens(todayTotal))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(provider.displayName)，\(isCollapsed ? "已折叠" : "已展开")")

            if !isCollapsed {
                ForEach(accounts) { account in
                    AccountCard(account: account)
                }
            }
        }
    }
}

struct AccountCard: View {
    @EnvironmentObject var model: AppModel
    let account: Account

    var body: some View {
        let usage = model.usage[account.id]
        VStack(alignment: .leading, spacing: 10) {
            if let usage {
                content(usage)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(account.name).font(.subheadline.weight(.medium))
                    Text("读取中…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    @ViewBuilder
    private func content(_ usage: AccountUsage) -> some View {
        // Name and today's total
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name).font(.subheadline.weight(.semibold))
                if let last = usage.lastActivity {
                    Text("最近活动 \(Fmt.relative(last))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text(Fmt.tokens(model.displayTotal(usage.today)))
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("今日").font(.caption2).foregroundStyle(.secondary)
            }
        }

        if let message = Fmt.statusText(usage.status), usage.status != .noRecentData {
            StatusLine(systemImage: "exclamationmark.triangle", text: message)
        } else {
            HStack(spacing: 16) {
                StatChip(title: "近 7 天", value: model.displayTotal(usage.last7Days))
                StatChip(title: "本月", value: model.displayTotal(usage.month))
                Spacer()
            }
            if !usage.today.isZero {
                SplitBar(tokens: usage.today)
            }
            if usage.daily.contains(where: { !$0.tokens.isZero }) {
                DailyBars(days: usage.daily, value: { model.displayTotal($0) })
            } else if usage.status == .noRecentData {
                StatusLine(systemImage: "moon.zzz", text: "本月暂无用量记录")
            }
        }

        quotaSection(usage)
    }

    @ViewBuilder
    private func quotaSection(_ usage: AccountUsage) -> some View {
        let result = model.quota[account.id]
        let effective = QuotaMerge.effective(local: usage.quota, online: result?.observation)
        if let effective {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(effective.observation.windows.enumerated()), id: \.offset) { _, window in
                    QuotaBar(window: window)
                }
                Text(effective.isOnline ? "额度来自在线查询 · \(Fmt.relative(effective.observation.observedAt))"
                                        : "额度来自本地日志 · \(Fmt.relative(effective.observation.observedAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        if let issue = result?.issue, issue != .disabled, issue != .unsupported {
            StatusLine(systemImage: "exclamationmark.circle", text: issue.message)
        }
    }
}

struct StatusLine: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct StatChip: View {
    let title: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Fmt.tokens(value))
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Today's input / output / cache split as a proportional bar with a text legend (not colour-only).
struct SplitBar: View {
    let tokens: TokenBreakdown

    private var parts: [(String, Int, Color)] {
        [("输入", tokens.input, Color.blue), ("输出", tokens.output, Color.orange), ("缓存", tokens.cache, Color.gray)]
    }

    var body: some View {
        let total = max(1, parts.reduce(0) { $0 + $1.1 })
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        if part.1 > 0 {
                            Rectangle()
                                .fill(part.2.opacity(0.85))
                                .frame(width: max(2, geo.size.width * CGFloat(part.1) / CGFloat(total)))
                        }
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 6)
            HStack(spacing: 10) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    HStack(spacing: 3) {
                        Circle().fill(part.2.opacity(0.85)).frame(width: 6, height: 6)
                        Text("\(part.0) \(Fmt.tokens(part.1))").monospacedDigit()
                    }
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .help("缓存读取 \(TokenFormatter.grouped(tokens.cacheRead)) / 缓存写入 \(TokenFormatter.grouped(tokens.cacheWrite))")
    }
}

/// Seven daily columns built from plain shapes.
struct DailyBars: View {
    let days: [DailyUsage]
    let value: (TokenBreakdown) -> Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let values = days.map { value($0.tokens) }
        let peak = max(1, values.max() ?? 1)
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                let isToday = index == days.count - 1
                VStack(spacing: 3) {
                    ZStack(alignment: .bottom) {
                        Color.clear.frame(height: 34)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.accentColor.opacity(isToday ? 1 : 0.45))
                            .frame(height: max(2, 34 * CGFloat(values[index]) / CGFloat(peak)))
                            .animation(reduceMotion ? nil : Animation.easeOut(duration: 0.25), value: values[index])
                    }
                    Text(Fmt.weekdayInitial(day.day))
                        .font(.system(size: 9))
                        .foregroundStyle(isToday ? .primary : .secondary)
                }
                .frame(maxWidth: .infinity)
                .help("\(Fmt.dayMonth(day.day))：\(TokenFormatter.grouped(values[index])) tokens")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Fmt.dayMonth(day.day)) \(Fmt.tokens(values[index])) tokens")
            }
        }
    }
}

struct QuotaBar: View {
    let window: QuotaWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var stale: Bool { window.isStale(at: Date()) }

    private var fill: Color {
        if stale { return .gray }
        switch window.usedPercent {
        case ..<70: return .green
        case ..<90: return .orange
        default: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(window.label).font(.caption)
                Spacer()
                if stale {
                    Text("窗口已重置，使用后更新").font(.caption2).foregroundStyle(.secondary)
                } else {
                    if let reset = window.resetsAt {
                        Text("\(Fmt.relative(reset))重置").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("\(Int(window.usedPercent.rounded()))%")
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(fill)
                        .frame(width: geo.size.width * CGFloat(min(100, max(0, stale ? 0 : window.usedPercent)) / 100))
                        .animation(reduceMotion ? nil : Animation.easeOut(duration: 0.25), value: window.usedPercent)
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.label) 已用 \(Int(window.usedPercent.rounded()))%")
    }
}
