import SwiftUI
import TokenBarCore

/// Snapshots of the menu bar window (overview, account detail) and the menu bar label.
@MainActor
enum PopoverShots {
    /// The fixed account ids of the demo data (see `DemoID` in TokenBarCore).
    fileprivate enum Demo {
        static func id(_ n: Int) -> UUID {
            UUID(uuidString: String(format: "DE300000-0000-4000-8000-%012d", n)) ?? UUID()
        }
        static let claudeMain = id(1)
        static let claudeWork = id(2)
        static let codex = id(3)
        static let gemini = id(4)
        static let museMax = id(5)
        static let museFree = id(6)
        static let museCode = id(7)
    }

    static var all: [SnapshotRunner.Shot] {
        let popover: () -> AnyView = { AnyView(PopoverView()) }
        let menuBar: () -> AnyView = { AnyView(MenuBarSnapshot()) }
        func detail(_ id: UUID) -> () -> AnyView { { AnyView(PopoverView(startAccountID: id)) } }
        return [
            // Overview
            .init(name: "popover-rich", scenario: .rich, menuBarWindow: true, content: popover),
            .init(name: "popover-sparse", scenario: .sparse, menuBarWindow: true, content: popover),
            .init(name: "popover-empty", scenario: .empty, menuBarWindow: true, content: popover),
            .init(name: "popover-scanning", scenario: .scanning, menuBarWindow: true, content: popover),
            .init(name: "popover-all-off", scenario: .allOff, menuBarWindow: true, content: popover),
            .init(name: "popover-loading", scenario: .loading, menuBarWindow: true, content: popover),
            .init(name: "popover-online-quota-off", scenario: .rich, menuBarWindow: true,
                  tweak: { $0.config.settings.onlineQuotaEnabled = false; $0.quota = [:]; $0.webQuota = [:] },
                  content: popover),
            .init(name: "popover-elevated", scenario: .rich, menuBarWindow: true, tweak: Tweak.elevated, content: popover),
            .init(name: "popover-quota-reset", scenario: .rich, menuBarWindow: true, tweak: Tweak.claudeQuotaReset, content: popover),
            .init(name: "popover-no-recent-usage", scenario: .rich, menuBarWindow: true, tweak: Tweak.geminiIdle, content: popover),
            .init(name: "popover-long-names", scenario: .rich, menuBarWindow: true, tweak: Tweak.longNames, content: popover),
            .init(name: "popover-muse-only", scenario: .rich, menuBarWindow: true,
                  tweak: { state in
                      for i in state.config.accounts.indices where state.config.accounts[i].providerID != "museai" {
                          state.config.accounts[i].isEnabled = false
                      }
                  }, content: popover),

            // Account detail
            .init(name: "popover-detail-claude", scenario: .rich, menuBarWindow: true, content: detail(Demo.claudeMain)),
            .init(name: "popover-detail-claude-sign-in", scenario: .rich, menuBarWindow: true, content: detail(Demo.claudeWork)),
            .init(name: "popover-detail-codex", scenario: .rich, menuBarWindow: true, content: detail(Demo.codex)),
            .init(name: "popover-detail-gemini", scenario: .rich, menuBarWindow: true, content: detail(Demo.gemini)),
            .init(name: "popover-detail-muse", scenario: .rich, menuBarWindow: true, content: detail(Demo.museMax)),
            .init(name: "popover-detail-muse-expired", scenario: .rich, menuBarWindow: true, content: detail(Demo.museFree)),
            .init(name: "popover-detail-muse-code", scenario: .rich, menuBarWindow: true, content: detail(Demo.museCode)),
            .init(name: "popover-detail-loading", scenario: .loading, menuBarWindow: true, content: detail(Demo.claudeMain)),
            .init(name: "popover-detail-sparse", scenario: .sparse, menuBarWindow: true, content: detail(Demo.claudeMain)),
            .init(name: "popover-detail-online-quota-off", scenario: .rich, menuBarWindow: true,
                  tweak: { $0.config.settings.onlineQuotaEnabled = false; $0.quota = [:] },
                  content: detail(Demo.claudeMain)),
            .init(name: "popover-detail-folder-missing", scenario: .rich, menuBarWindow: true,
                  tweak: Tweak.claudeFolderMissing, content: detail(Demo.claudeMain)),
            .init(name: "popover-detail-quota-reset", scenario: .rich, menuBarWindow: true,
                  tweak: Tweak.claudeQuotaReset, content: detail(Demo.claudeMain)),
            .init(name: "popover-detail-long-names", scenario: .rich, menuBarWindow: true,
                  tweak: Tweak.longNames, content: detail(Demo.museMax)),

            // Menu bar label
            .init(name: "popover-menubar-tokens", scenario: .rich, content: menuBar),
            .init(name: "popover-menubar-peak", scenario: .rich,
                  tweak: { $0.config.settings.menuBarMetric = .peakQuota }, content: menuBar),
            .init(name: "popover-menubar-icon-only", scenario: .rich,
                  tweak: { $0.config.settings.menuBarShowsNumber = false }, content: menuBar),
            .init(name: "popover-menubar-warning-other-provider", scenario: .rich,
                  tweak: { $0.config.settings.menuBarProviderID = "gemini" }, content: menuBar),
            .init(name: "popover-menubar-normal", scenario: .sparse, content: menuBar),
            .init(name: "popover-menubar-empty", scenario: .empty, content: menuBar),
        ]
    }
}

/// Changes to the demo data for single shots.
private enum Tweak {
    static let claude = PopoverShots.Demo.claudeMain

    /// Every window of every account through `change`, local and online readings alike.
    static func mapWindows(_ state: inout DemoState, _ change: (UUID, QuotaWindow) -> QuotaWindow) {
        for id in state.quota.keys {
            if let observation = state.quota[id]?.observation {
                state.quota[id]?.observation?.windows = observation.windows.map { change(id, $0) }
            }
        }
        for id in state.usage.keys {
            if let local = state.usage[id]?.quota {
                state.usage[id]?.quota?.windows = local.windows.map { change(id, $0) }
            }
        }
        for id in state.webQuota.keys {
            if let usage = state.webQuota[id]?.usage {
                state.webQuota[id]?.usage?.windows = usage.windows.map { change(id, $0) }
            }
        }
    }

    /// Nothing critical anywhere; the main Claude account's weekly window at 80 % (orange).
    static func elevated(_ state: inout DemoState) {
        mapWindows(&state) { id, window in
            var window = window
            window.usedPercent = (id == claude && window.label.hasPrefix("Weekly")) ? 80 : min(window.usedPercent, 55)
            return window
        }
    }

    /// Every window of the main Claude account has reset since it was read.
    static func claudeQuotaReset(_ state: inout DemoState) {
        let resetAt = (state.lastRefresh ?? Date()).addingTimeInterval(-600)
        mapWindows(&state) { id, window in
            guard id == claude else { return window }
            var window = window
            window.resetsAt = resetAt
            return window
        }
    }

    /// Gemini CLI unused this month: no tokens, no activity, no quota.
    static func geminiIdle(_ state: inout DemoState) {
        let id = PopoverShots.Demo.gemini
        state.quota[id] = nil
        guard var usage = state.usage[id] else { return }
        usage.today = .zero
        usage.last7Days = .zero
        usage.month = .zero
        usage.daily = usage.daily.map { DailyUsage(day: $0.day) }
        usage.quota = nil
        usage.lastActivity = nil
        usage.status = .noRecentData
        state.usage[id] = usage
    }

    /// The main Claude account's folder is gone.
    static func claudeFolderMissing(_ state: inout DemoState) {
        guard var usage = state.usage[claude] else { return }
        usage.today = .zero
        usage.last7Days = .zero
        usage.month = .zero
        usage.daily = usage.daily.map { DailyUsage(day: $0.day) }
        usage.quota = nil
        usage.lastActivity = nil
        usage.status = .dataDirectoryMissing
        state.usage[claude] = usage
        state.quota[claude] = nil
    }

    /// A long account name next to a long Muse plan name, and a long quota window label.
    static func longNames(_ state: inout DemoState) {
        if let i = state.config.accounts.firstIndex(where: { $0.id == claude }) {
            state.config.accounts[i].name = "alexandra.konstantinopoulou@example.com"
        }
        if let i = state.config.accounts.firstIndex(where: { $0.id == PopoverShots.Demo.museMax }) {
            state.config.accounts[i].name = "Muse for the whole design studio team"
        }
        state.webQuota[PopoverShots.Demo.museMax]?.usage?.planName = "Maximum Plus Annual"
        // A long window label too, so the peak line has to drop the provider name.
        mapWindows(&state) { id, window in
            guard id == claude, window.label.hasPrefix("Weekly") else { return window }
            var window = window
            window.label = "Weekly (Opus and Sonnet)"
            return window
        }
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
