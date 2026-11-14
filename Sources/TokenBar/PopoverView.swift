import SwiftUI
import AppKit
import TokenBarCore

struct PopoverView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.accounts.isEmpty {
                        Text("尚未添加账户。请打开“设置”添加 Codex、Claude、Gemini 或 Muse 账户。")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                    ForEach(model.registry.providers, id: \.id) { provider in
                        let accounts = model.accounts(for: provider.id)
                        if !accounts.isEmpty {
                            ProviderSection(provider: provider, accounts: accounts)
                        }
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 460)
            Divider()
            footer
        }
        .frame(width: 380)
        .onAppear { model.refreshIfStale() }
    }

    private var header: some View {
        HStack {
            Text("TokenBar").font(.headline)
            Spacer()
            if model.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("立即刷新")
            .disabled(model.isRefreshing)
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
            }
            Spacer()
            Button("设置…") { SettingsWindowController.shared.show(model: model) }
                .buttonStyle(.borderless)
            Button("退出") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct ProviderSection: View {
    @EnvironmentObject var model: AppModel
    let provider: any UsageProvider
    let accounts: [Account]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(provider.displayName, systemImage: provider.symbolName)
                .font(.subheadline.weight(.semibold))
            ForEach(accounts) { account in
                AccountCard(account: account, usage: model.usage[account.id])
            }
        }
    }
}

struct AccountCard: View {
    let account: Account
    let usage: AccountUsage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(account.name).font(.callout.weight(.medium))
                Spacer()
                if let last = usage?.lastActivity {
                    Text("最近活动 \(Fmt.relative(last))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let usage {
                if let message = Fmt.statusText(usage.status), usage.status != .noRecentData {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                } else {
                    UsageGrid(usage: usage)
                    if let quota = usage.quota {
                        ForEach(Array(quota.windows.enumerated()), id: \.offset) { _, window in
                            QuotaBar(window: window, observedAt: quota.observedAt)
                        }
                    }
                }
            } else {
                Text("加载中…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }
}

struct UsageGrid: View {
    let usage: AccountUsage

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 3) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                header("输入"); header("输出"); header("缓存"); header("合计")
            }
            row("今日", usage.today)
            row("近 7 天", usage.last7Days)
            row("本月", usage.month)
        }
        .font(.caption)
    }

    private func header(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary)
    }

    private func row(_ title: String, _ b: TokenBreakdown) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.leading)
            Text(Fmt.tokens(b.input))
            Text(Fmt.tokens(b.output))
            Text(Fmt.tokens(b.cache))
                .help("缓存读取 \(TokenFormatter.grouped(b.cacheRead)) / 缓存写入 \(TokenFormatter.grouped(b.cacheWrite))")
            Text(Fmt.tokens(b.total)).fontWeight(.semibold)
                .help("输入 + 输出 = \(TokenFormatter.grouped(b.totalExcludingCache))")
        }
        .monospacedDigit()
    }
}

struct QuotaBar: View {
    let window: QuotaWindow
    let observedAt: Date

    var body: some View {
        let stale = window.isStale(at: Date())
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(window.label).font(.caption)
                Spacer()
                if stale {
                    Text("窗口已重置（待下次使用时更新）").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("\(Int(window.usedPercent.rounded()))%").font(.caption).monospacedDigit()
                    if let r = window.resetsAt {
                        Text("· \(Fmt.relative(r))重置").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(stale ? Color.gray : color)
                        .frame(width: geo.size.width * CGFloat(min(100, max(0, window.usedPercent)) / 100))
                }
            }
            .frame(height: 6)
            .opacity(stale ? 0.5 : 1)
        }
    }

    private var color: Color {
        switch window.usedPercent {
        case ..<70: return .green
        case ..<90: return .orange
        default: return .red
        }
    }
}
