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
            if model.enabledAccounts.isEmpty {
                EmptyState()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(model.catalog.providers) { provider in
                            let accounts = model.enabledAccounts(for: provider.id)
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
            .help("Refresh now (⌘R)")
            .accessibilityLabel("Refresh now")
            .disabled(model.isRefreshing)

            Button {
                SettingsWindowController.shared.show(model: model)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(",")
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            if let last = model.lastRefresh {
                Text("Updated \(Fmt.clockTime(last))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Reading…").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
                .help("Quit TokenBar (⌘Q)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct EmptyState: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            if !model.hasScanned || model.isScanning {
                ProgressView().controlSize(.small)
                Text("Looking for accounts…").font(.headline)
            } else if !model.accounts.isEmpty {
                Image(systemName: "eye.slash").font(.system(size: 30)).foregroundStyle(.secondary)
                Text("All accounts are turned off").font(.headline)
                Button("Open settings") { SettingsWindowController.shared.show(model: model) }
            } else {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text("No accounts found").font(.headline)
                Text("TokenBar looks for Claude Code, Codex, Gemini CLI and Muse Code on this Mac. Sign in below to add an account, including Muse.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(model.catalog.providers) { provider in
                    if model.signInUnavailableReason(provider.id) == nil {
                        Button("Sign in to \(provider.displayName)") {
                            model.startSignIn(provider.id)
                            // CLI sign-ins report progress in settings; a web sign-in has its own window.
                            if provider.capabilities.signIn == .cli {
                                SettingsWindowController.shared.show(model: model)
                            }
                        }
                        .disabled(provider.capabilities.signIn == .web && model.isSigningInToMuse)
                    }
                }
                HStack {
                    Button("Look again") { Task { await model.rescan() } }
                    Button("Open settings") { SettingsWindowController.shared.show(model: model) }
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

struct ProviderSection: View {
    @EnvironmentObject var model: AppModel
    let provider: ProviderInfo
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
                    if provider.capabilities.localLogs {
                        Text("Today \(Fmt.tokens(todayTotal))")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(provider.displayName), \(isCollapsed ? "collapsed" : "expanded")")

            if !isCollapsed {
                ForEach(accounts) { account in
                    if provider.capabilities.localLogs {
                        AccountCard(account: account)
                    } else {
                        WebQuotaCard(account: account)
                    }
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
                    Text("Reading…").font(.caption).foregroundStyle(.secondary)
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
                    Text("Last active \(Fmt.relative(last))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text(Fmt.tokens(model.displayTotal(usage.today)))
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("Today").font(.caption2).foregroundStyle(.secondary)
            }
        }

        if let message = Fmt.statusText(usage.status), usage.status != .noRecentData {
            StatusLine(systemImage: "exclamationmark.triangle", text: message)
        } else {
            HStack(spacing: 16) {
                StatChip(title: "Last 7 days", value: model.displayTotal(usage.last7Days))
                StatChip(title: "This month", value: model.displayTotal(usage.month))
                Spacer()
            }
            if !usage.today.isZero {
                SplitBar(tokens: usage.today)
            }
            if usage.daily.contains(where: { !$0.tokens.isZero }) {
                DailyBars(days: usage.daily, value: { model.displayTotal($0) })
            } else if usage.status == .noRecentData {
                StatusLine(systemImage: "moon.zzz", text: "No usage this month")
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
                Text(effective.isOnline ? "Quota from online check · \(Fmt.relative(effective.observation.observedAt))"
                                        : "Quota from local logs · \(Fmt.relative(effective.observation.observedAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        if let issue = result?.issue, issue != .disabled, issue != .unsupported {
            StatusLine(systemImage: "exclamationmark.circle", text: issue.message)
        }
    }
}

/// Card for an account without local logs (Muse): plan, weekly quota with reset countdown, tokens left, top-up.
struct WebQuotaCard: View {
    @EnvironmentObject var model: AppModel
    let account: Account

    var body: some View {
        let state = model.webQuota[account.id]
        let usage = state?.usage
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name).font(.subheadline.weight(.semibold))
                    if let plan = usage?.planName {
                        Text(plan).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            if !model.onlineQuotaIsOn(for: account) {
                StatusLine(systemImage: "wifi.slash", text: "Online quota is off. Turn it on in Settings to see Muse usage.")
            } else {
                if let usage {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(usage.windows.enumerated()), id: \.offset) { _, window in
                            QuotaBar(window: window)
                        }
                        ForEach(usage.detailLines, id: \.self) { line in
                            Text(line).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("From muse.ai · \(Fmt.relative(usage.observedAt))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if state?.failure == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let failure = state?.failure {
                    StatusLine(systemImage: "exclamationmark.circle", text: failure.message)
                    if failure.needsSignIn {
                        Button("Sign in again") { model.signInToMuse(replacing: account.id) }
                            .disabled(model.isSigningInToMuse)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
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
        [("Input", tokens.input, Color.blue), ("Output", tokens.output, Color.orange), ("Cache", tokens.cache, Color.gray)]
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
        .help("Cache read \(TokenFormatter.grouped(tokens.cacheRead)) / cache write \(TokenFormatter.grouped(tokens.cacheWrite))")
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
                .help("\(Fmt.dayMonth(day.day)): \(TokenFormatter.grouped(values[index])) tokens")
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
                    Text("Window reset, updates after use").font(.caption2).foregroundStyle(.secondary)
                } else {
                    if let reset = window.resetsAt {
                        Text("Resets \(Fmt.relative(reset))").font(.caption2).foregroundStyle(.secondary)
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
        .accessibilityLabel("\(window.label) \(Int(window.usedPercent.rounded()))% used")
    }
}
