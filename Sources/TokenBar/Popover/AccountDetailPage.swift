import SwiftUI
import TokenBarCore

/// One account inside the menu bar window: token numbers, last seven days, split and quota.
/// The back button (or Esc) returns to the overview.
struct AccountDetailPage: View {
    @EnvironmentObject var model: AppModel
    let account: Account
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text(model.providerName(of: account))
                    }
                    .foregroundColor(.accentColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Back (Esc)")
                .accessibilityLabel("Back to all accounts")
                Spacer()
            }
            .padding(.horizontal, PopoverStyle.horizontalPadding - 2)
            .frame(height: 36)
            Divider()
            PopoverScrollHeight(cap: PopoverStyle.maxScrollHeight) {
                ScrollView {
                    // Relative times stay current while the window is open.
                    TimelineView(.periodic(from: .now, by: PopoverStyle.clockInterval)) { context in
                        AccountDetailContent(account: account, now: context.date)
                    }
                }
            }
        }
    }
}

private struct AccountDetailContent: View {
    @EnvironmentObject var model: AppModel
    let account: Account
    let now: Date

    var body: some View {
        let kind = model.detailKind(for: account)
        VStack(alignment: .leading, spacing: 14) {
            title(kind: kind, now: now)
            if kind.showsTokens {
                tokens
            }
            if kind == .logsWithQuota {
                cliQuota(now: now)
            } else if kind == .webQuota {
                webQuota(now: now)
            }
            Button("Account Settings…") {
                SettingsWindowController.shared.show(model: model, tab: .accounts, accountID: account.id)
            }
        }
        .padding(.horizontal, PopoverStyle.horizontalPadding)
        .padding(.top, PopoverStyle.verticalPadding)
        .padding(.bottom, PopoverStyle.verticalPadding + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Title

    @ViewBuilder
    private func title(kind: AccountDetailKind, now: Date) -> some View {
        let subtitle = kind == .webQuota
            ? PopoverText.planLine(accountName: account.name, planName: model.webQuota[account.id]?.usage?.planName)
            : PopoverText.identityLine(accountName: account.name, identity: model.identities[account.id])
        VStack(alignment: .leading, spacing: 2) {
            Text(account.name)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(account.name)
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if kind.showsTokens, let last = model.usage[account.id]?.lastActivity {
                Text("Last active \(AgoPhrase.since(last, now: now))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Tokens

    @ViewBuilder
    private var tokens: some View {
        if let usage = model.usage[account.id] {
            let problem = usage.status == .noRecentData ? nil : Fmt.statusText(usage.status)
            let unreadable = usage.status == .dataDirectoryMissing || usage.status == .unknownProvider
            // Missing data is not zero usage: no tiles when the logs could not be read at all.
            if !unreadable {
                HStack(spacing: 8) {
                    StatTile(title: "Today", value: model.displayTotal(usage.today))
                    StatTile(title: "Last 7 days", value: model.displayTotal(usage.last7Days))
                    StatTile(title: "This month", value: model.displayTotal(usage.month))
                }
            }
            if let problem {
                AttentionLine(text: problem)
            } else if usage.daily.contains(where: { !$0.tokens.isZero }) {
                VStack(alignment: .leading, spacing: 8) {
                    PopoverSectionLabel(title: "Last 7 days", inset: 0)
                    DailyBars(days: usage.daily, value: { model.displayTotal($0) })
                    if !usage.today.isZero {
                        SplitBar(tokens: usage.today, title: "Today")
                            .padding(.top, 6)
                    }
                }
            } else {
                StatusLine(systemImage: "moon.zzz", text: "No usage in the last 7 days")
            }
        } else {
            ReadingLine()
        }
    }

    // MARK: Quota (CLI accounts)

    @ViewBuilder
    private func cliQuota(now: Date) -> some View {
        let quota = model.quotaWindows(for: account)
        let attention = model.attentionMessage(for: account)
        let usageProblem = model.usage[account.id].map { $0.status == .dataDirectoryMissing || $0.status == .unknownProvider } ?? false
        // While nothing is known yet the token section already says "Reading…".
        let nothingYet = quota.windows.isEmpty && attention == nil && model.quota[account.id] == nil
            && model.onlineQuotaIsOn(for: account)
        // With unreadable logs the token section already names the problem; an empty quota section adds nothing.
        if !nothingYet && !(usageProblem && quota.windows.isEmpty) {
            VStack(alignment: .leading, spacing: 8) {
                PopoverSectionLabel(title: "Quota", inset: 0)
                if !quota.windows.isEmpty {
                    quotaGroup(quota.windows, now: now)
                    if let observed = quota.observedAt {
                        Text(PopoverText.quotaSource(kind: .logsWithQuota, isOnline: quota.isOnline, observedAt: observed, now: now))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let attention, !usageProblem {
                    AttentionLine(text: attention)
                } else if let issue = model.quota[account.id]?.issue, issue.isAwaitingCLIRenewal {
                    // Routine: the CLI renews its own sign-in the next time it runs.
                    StatusLine(systemImage: "clock", text: issue.message)
                } else if quota.windows.isEmpty {
                    if !model.onlineQuotaIsOn(for: account) {
                        StatusLine(systemImage: "wifi.slash", text: "Online quota is off. Turn it on in Settings to see quota.")
                    } else {
                        StatusLine(systemImage: "chart.bar", text: "No quota reported yet")
                    }
                }
            }
        }
    }

    private func quotaGroup(_ windows: [QuotaWindow], now: Date) -> some View {
        PopoverGroup {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(windows.indices, id: \.self) { i in
                    QuotaBar(window: windows[i], now: now)
                }
            }
            .padding(12)
        }
    }

    // MARK: Quota (Muse)

    @ViewBuilder
    private func webQuota(now: Date) -> some View {
        let state = model.webQuota[account.id]
        VStack(alignment: .leading, spacing: 8) {
            PopoverSectionLabel(title: "Quota", inset: 0)
            if !model.onlineQuotaIsOn(for: account) {
                StatusLine(systemImage: "wifi.slash", text: "Online quota is off. Turn it on in Settings to see Muse usage.")
            } else {
                if let usage = state?.usage {
                    PopoverGroup {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(usage.windows.indices, id: \.self) { i in
                                QuotaBar(window: usage.windows[i], now: now)
                            }
                            if let left = usage.tokensLeft {
                                valueRow("Plan tokens", PopoverText.amountLeft(left))
                            }
                            if let topUp = usage.topUp {
                                VStack(alignment: .leading, spacing: 5) {
                                    valueRow(topUp.label, PopoverText.amountLeft(topUp.value))
                                    PopoverBar(fraction: topUp.usedFraction, tint: .accentColor)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .padding(12)
                    }
                    let source = PopoverText.quotaSource(kind: .webQuota, isOnline: true, observedAt: usage.observedAt, now: now)
                    Text([source, PopoverText.renewal(usage.renewsAt, now: now)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if state?.failure == nil {
                    ReadingLine()
                }
                if let failure = state?.failure {
                    VStack(alignment: .leading, spacing: 8) {
                        // The button says what to do, so the line only names the problem.
                        AttentionLine(text: failure.needsSignIn ? PopoverText.museProblem(failure) : failure.message)
                        if failure.needsSignIn {
                            Button("Sign in again…") { model.signInToMuse(replacing: account.id) }
                                .disabled(model.isSigningInToMuse)
                        }
                    }
                }
            }
        }
    }

    private func valueRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.callout)
            Spacer(minLength: 8)
            Text(value)
                .font(.callout.weight(.medium))
                .monospacedDigit()
        }
    }
}
