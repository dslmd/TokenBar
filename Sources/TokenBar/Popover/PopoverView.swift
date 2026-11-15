import SwiftUI
import AppKit
import TokenBarCore

/// Content of the menu bar window: the overview, or the detail page of one account.
struct PopoverView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection: UUID?

    /// - Parameter startAccountID: open on that account's detail page (snapshots); nil opens the overview.
    init(startAccountID: UUID? = nil) {
        _selection = State(initialValue: startAccountID)
    }

    var body: some View {
        ZStack(alignment: .top) {
            if let id = selection, let account = model.popoverAccount(withID: id) {
                AccountDetailPage(account: account, onBack: { show(nil) })
                    .transition(.move(edge: .trailing))
            } else {
                PopoverOverview(onOpen: { show($0) })
                    .transition(.move(edge: .leading))
            }
        }
        .frame(width: PopoverStyle.width)
        .clipped()
        .background(shortcuts)
        .background(PopoverWindowObserver(onOpen: { model.refreshIfStale() }, onClose: resetToOverview))
        .onAppear { model.refreshIfStale() }
    }

    /// The menu bar window keeps this view alive between openings: start every opening on the overview.
    private func resetToOverview() {
        guard selection != nil else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { selection = nil }
    }

    private func show(_ id: UUID?) {
        withAnimation(PopoverStyle.animation(reduceMotion: reduceMotion)) { selection = id }
    }

    /// Window-wide shortcuts that work whichever page is shown (the "more" menu shows them too).
    private var shortcuts: some View {
        ZStack {
            Button("Refresh") { PopoverActions.refresh(model) }
                .keyboardShortcut("r")
            Button("Settings…") { PopoverActions.openSettings(model) }
                .keyboardShortcut(",")
            Button("Quit TokenBar") { PopoverActions.quit() }
                .keyboardShortcut("q")
        }
        .buttonStyle(.plain)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

/// What the buttons and shortcuts of the menu bar window do.
@MainActor
enum PopoverActions {
    static func refresh(_ model: AppModel) {
        Task { await model.refresh(force: true) }
    }

    static func openSettings(_ model: AppModel) {
        SettingsWindowController.shared.show(model: model)
    }

    static func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Overview

struct PopoverOverview: View {
    @EnvironmentObject var model: AppModel
    let onOpen: (UUID) -> Void

    var body: some View {
        let screen = model.popoverScreen
        VStack(spacing: 0) {
            if screen == .accounts {
                // Relative times ("Updated 2 min ago", stale windows) stay current while the window is open.
                TimelineView(.periodic(from: .now, by: PopoverStyle.clockInterval)) { context in
                    VStack(spacing: 0) {
                        PopoverHeader(now: context.date)
                        Divider()
                        PopoverScrollHeight(cap: PopoverStyle.maxScrollHeight) {
                            ScrollView {
                                PopoverAccountList(now: context.date, onOpen: onOpen)
                            }
                        }
                        Divider()
                        PopoverFooter(now: context.date)
                    }
                }
            } else {
                PopoverPlainHeader()
                Divider()
                PopoverStateView(screen: screen)
            }
        }
    }
}

/// "Today", the hero number and the peak quota line, with refresh and the "more" menu.
struct PopoverHeader: View {
    @EnvironmentObject var model: AppModel
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 4) {
                Text("Today")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                PopoverRefreshButton()
                PopoverMoreMenu()
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if let total = model.heroTodayTokens {
                    Text(PopoverText.heroTokens(total))
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .help("\(TokenFormatter.grouped(total)) tokens today")
                    Text("tokens")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                } else {
                    // Same height as the number, so the header does not jump when the first numbers arrive.
                    Text("Reading…")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(height: 34, alignment: .center)
                }
            }
            .accessibilityElement(children: .combine)
            if let peak = model.peakQuota(now: now) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(PopoverStyle.tint(peak.summary.level))
                        .frame(width: 7, height: 7)
                    PeakQuotaText(peak: peak)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Highest quota: \(peak.text)")
            }
        }
        .padding(.horizontal, PopoverStyle.horizontalPadding)
        .padding(.top, 8)
        .padding(.bottom, PopoverStyle.verticalPadding)
    }
}

/// "Weekly 93% · Claude Code · resets in 2 days" with the percentage tinted. When that does not fit,
/// the provider name gives way first, so the reset phrase (the part to act on) stays readable.
private struct PeakQuotaText: View {
    let peak: PeakQuota

    var body: some View {
        ViewThatFits(in: .horizontal) {
            line(showsProvider: true)
            line(showsProvider: false)
                .truncationMode(.tail)
        }
    }

    private func line(showsProvider: Bool) -> some View {
        let summary = peak.summary
        let percent = Text(summary.percentText).fontWeight(.semibold)
        let tinted = PopoverStyle.textTint(summary.level).map { percent.foregroundColor($0) } ?? percent
        let parts = [showsProvider ? peak.providerName : nil, summary.resetPhrase].compactMap { $0 }
        let tail = parts.isEmpty ? Text("") : Text(" · " + parts.joined(separator: " · "))
        return (Text("\(summary.label) ") + tinted + tail)
            .monospacedDigit()
            .lineLimit(1)
    }
}

/// Header for the states without accounts: the app name and the "more" menu.
private struct PopoverPlainHeader: View {
    var body: some View {
        HStack(spacing: 4) {
            Text("TokenBar")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            PopoverMoreMenu()
        }
        .padding(.horizontal, PopoverStyle.horizontalPadding)
        .padding(.vertical, 8)
    }
}

private struct PopoverRefreshButton: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button {
            PopoverActions.refresh(model)
        } label: {
            ZStack {
                if model.isRefreshing {
                    ProgressView().controlSize(.small).scaleEffect(0.75)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .frame(width: 24, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .disabled(model.isRefreshing)
        .help("Refresh (⌘R)")
        .accessibilityLabel("Refresh")
    }
}

/// The "more" menu: Refresh, Settings…, Quit TokenBar.
private struct PopoverMoreMenu: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Menu {
            Button("Refresh") { PopoverActions.refresh(model) }
                .keyboardShortcut("r")
            Button("Settings…") { PopoverActions.openSettings(model) }
                .keyboardShortcut(",")
            Divider()
            Button("Quit TokenBar") { PopoverActions.quit() }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14, weight: .regular))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 24, height: 22)
        .help("More")
        .accessibilityLabel("More")
    }
}

private struct PopoverFooter: View {
    @EnvironmentObject var model: AppModel
    let now: Date

    var body: some View {
        HStack {
            Text(model.isRefreshing ? "Updating…" : PopoverText.footer(lastRefresh: model.lastRefresh, now: now))
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(model.lastRefresh.map { "Last updated at \(Fmt.clockTime($0))" } ?? "")
            Spacer()
        }
        .padding(.horizontal, PopoverStyle.horizontalPadding)
        .padding(.vertical, 8)
    }
}

/// One section per provider, one compact row per account.
private struct PopoverAccountList: View {
    @EnvironmentObject var model: AppModel
    let now: Date
    let onOpen: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(model.catalog.providers) { provider in
                let accounts = model.enabledAccounts(for: provider.id)
                if !accounts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        PopoverSectionLabel(title: provider.displayName, systemImage: provider.symbolName,
                                            trailing: provider.capabilities.localLogs ? model.todayTokens(of: accounts).map(Fmt.tokens) : nil)
                        PopoverGroup {
                            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                                if index > 0 {
                                    Divider().padding(.leading, 12)
                                }
                                PopoverAccountRow(account: account, now: now, onOpen: { onOpen(account.id) })
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, PopoverStyle.horizontalPadding)
        .padding(.vertical, PopoverStyle.verticalPadding)
    }
}

/// Name, today's tokens (or the plan for Muse) and one summary line; opens the detail page.
struct PopoverAccountRow: View {
    @EnvironmentObject var model: AppModel
    let account: Account
    let now: Date
    let onOpen: () -> Void

    var body: some View {
        let line = model.rowLine(for: account, now: now)
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(account.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if let trailing {
                        Text(trailing)
                            .font(.body)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            // Only the name gives way to a long plan name or number.
                            .fixedSize()
                            .layoutPriority(1)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                lineView(line, now: now)
                if case .quota(let summary) = line {
                    PopoverBar(fraction: summary.fraction, tint: PopoverStyle.tint(summary.level), height: 3)
                        .padding(.top, 3)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PopoverRowButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows details")
    }

    private var trailing: String? {
        if model.detailKind(for: account) == .webQuota {
            return model.webQuota[account.id]?.usage?.planName
        }
        return model.usage[account.id].map { Fmt.tokens(model.displayTotal($0.today)) }
    }

    @ViewBuilder
    private func lineView(_ line: AccountRowLine, now: Date) -> some View {
        switch line {
        case .reading:
            ReadingLine()
        case .attention(let message):
            AttentionLine(text: message, lineLimit: 2)
        case .onlineQuotaOff:
            StatusLine(systemImage: "wifi.slash", text: "Online quota is off")
        case .quota(let summary):
            QuotaSummaryText(summary: summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .note(let text):
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        case .lastActive(let date):
            Text("Last active \(AgoPhrase.since(date, now: now))")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .noRecentUsage:
            Text("No usage this month")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .none:
            EmptyView()
        }
    }
}

// MARK: - States without accounts

private struct PopoverStateView: View {
    @EnvironmentObject var model: AppModel
    let screen: PopoverScreen

    var body: some View {
        VStack(spacing: 8) {
            switch screen {
            case .scanning, .accounts:
                ProgressView().controlSize(.small)
                    .padding(.bottom, 2)
                Text("Looking for accounts…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .noAccounts:
                symbol("person.crop.circle.badge.plus")
                Text("No accounts yet")
                    .font(.headline)
                Text(noAccountsText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 6) {
                    Button("Set up TokenBar…") { OnboardingWindowController.shared.show(model: model) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                    Button("Open Settings") { PopoverActions.openSettings(model) }
                        .buttonStyle(.borderless)
                }
                .padding(.top, 6)
            case .allTurnedOff:
                symbol("eye.slash")
                Text("All accounts are turned off")
                    .font(.headline)
                Text("Turn an account on in Settings to see its usage here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings") { PopoverActions.openSettings(model) }
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 22)
        .padding(.vertical, screen == .scanning ? 36 : 24)
    }

    private var noAccountsText: String {
        let providers = model.catalog.providers
        // Keep each provider name on one line ("Gemini CLI" never splits).
        func names(_ list: [ProviderInfo]) -> [String] { list.map { $0.displayName.replacingOccurrences(of: " ", with: "\u{00A0}") } }
        return PopoverText.noAccounts(localProviders: names(providers.filter { $0.capabilities.localLogs }),
                                      webProviders: names(providers.filter { !$0.capabilities.localLogs }))
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 30, weight: .regular))
            .foregroundStyle(.secondary)
            .padding(.bottom, 2)
            .accessibilityHidden(true)
    }
}
