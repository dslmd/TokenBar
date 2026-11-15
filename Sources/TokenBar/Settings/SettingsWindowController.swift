import SwiftUI
import AppKit
import TokenBarCore

/// The settings window's tabs. Other parts of the app open settings on a given tab.
enum SettingsTab: String, CaseIterable {
    case general, accounts, notifications

    var title: String {
        switch self {
        case .general: return "General"
        case .accounts: return "Accounts"
        case .notifications: return "Notifications"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .accounts: return "person.2"
        case .notifications: return "bell.badge"
        }
    }
}

/// Requests that travel from the window controller into the tab views: which account to scroll to and
/// which one to highlight for a moment.
@MainActor
final class SettingsNavigation: ObservableObject {
    /// Changes every time an account should be scrolled into view (the same account twice included).
    @Published private(set) var scrollRequest: (id: UUID, serial: Int)?
    @Published var highlightedAccountID: UUID?
    private var serial = 0
    private var clearTask: Task<Void, Never>?

    init(highlightedAccountID: UUID? = nil) {
        self.highlightedAccountID = highlightedAccountID
    }

    func reveal(_ id: UUID) {
        serial += 1
        scrollRequest = (id, serial)
        highlightedAccountID = id
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            self?.highlightedAccountID = nil
        }
    }
}

/// The settings window: a standard toolbar-tab window (General, Accounts, Notifications), one SwiftUI
/// grouped form per tab. A plain NSWindow avoids the `Settings` scene, which is unreliable to open from an
/// accessory (no Dock icon) app on macOS 13/14.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var tabs: SettingsTabViewController?
    private weak var model: AppModel?
    private let navigation = SettingsNavigation()

    /// Opens settings on `tab`. With `accountID`, the accounts tab scrolls to that account and highlights it.
    func show(model: AppModel, tab: SettingsTab, accountID: UUID? = nil) {
        let target: SettingsTab = accountID == nil ? tab : .accounts
        open(model: model, tab: target)
        if let accountID {
            // After the tab switch has laid the list out.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [navigation] in navigation.reveal(accountID) }
        }
    }

    /// Opens settings on the tab that was shown last (General the first time).
    func show(model: AppModel) {
        open(model: model, tab: nil)
    }

    private func open(model: AppModel, tab: SettingsTab?) {
        if window == nil || self.model !== model {
            build(model: model)
        }
        if let tab { tabs?.select(tab) }
        NotificationService.shared.refreshAuthorization()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build(model: AppModel) {
        window?.close()
        self.model = model
        let controller = SettingsTabViewController(model: model, navigation: navigation)
        let w = NSWindow(contentViewController: controller)
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.toolbarStyle = .preference
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setFrameAutosaveName("TokenBarSettings")
        controller.fitWindow(animated: false)
        if !w.setFrameUsingName("TokenBarSettings") { w.center() }
        controller.fitWindow(animated: false)
        tabs = controller
        window = w
    }

    func windowDidBecomeKey(_ notification: Notification) {
        NotificationService.shared.refreshAuthorization()
    }
}

/// Toolbar tabs with one hosting controller per tab. The window takes each tab's height (animated) and its
/// title follows the selected tab.
@MainActor
final class SettingsTabViewController: NSTabViewController {
    static let contentWidth: CGFloat = 620

    private let order = SettingsTab.allCases

    /// Each tab's root view, kept to measure its height (see `updateSizes`).
    private var roots: [SettingsTab: AnyView] = [:]

    init(model: AppModel, navigation: SettingsNavigation) {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        transitionOptions = [.crossfade, .allowUserInteraction]
        for tab in order {
            let root = SettingsTabContent(tab: tab, navigation: navigation) { [weak self] in
                // After SwiftUI has applied the change, so the new ideal height is measured.
                DispatchQueue.main.async { self?.fitWindow(animated: true) }
            }
                .environmentObject(model)
            roots[tab] = AnyView(root)
            let host = NSHostingController(rootView: AnyView(root))
            // The window size is set here, not by SwiftUI, so switching tabs animates once.
            host.sizingOptions = []
            host.title = tab.title
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: tab.title)
            item.identifier = tab.rawValue
            addTabViewItem(item)
        }
        updateSizes()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func select(_ tab: SettingsTab) {
        guard let index = order.firstIndex(of: tab), index != selectedTabViewItemIndex else { return }
        selectedTabViewItemIndex = index
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        view.window?.title = tabViewItem?.label ?? "Settings"
        fitWindow(animated: view.window?.isVisible == true)
    }

    /// Each tab's preferred size: fixed width, the content's ideal height within limits.
    private func updateSizes() {
        for (index, item) in tabViewItems.enumerated() {
            guard let host = item.viewController as? NSHostingController<AnyView>,
                  index < order.count, let root = roots[order[index]] else { continue }
            // A grouped Form scrolls, so sizeThatFits reports far less than its content. A throwaway hosting
            // view's intrinsic size is the full content height (the same measurement the snapshots use).
            let probe = NSHostingView(rootView: root)
            probe.layoutSubtreeIfNeeded()
            let height = SettingsRules.windowContentHeight(ideal: Double(probe.intrinsicContentSize.height))
            host.preferredContentSize = NSSize(width: Self.contentWidth, height: CGFloat(height))
        }
    }

    /// Resizes the window to the selected tab, keeping its top edge where it is.
    func fitWindow(animated: Bool) {
        updateSizes()
        guard isViewLoaded, let window = view.window, selectedTabViewItemIndex >= 0,
              let host = tabViewItems[selectedTabViewItemIndex].viewController else { return }
        window.title = tabViewItems[selectedTabViewItemIndex].label
        let size = host.preferredContentSize
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin.x = window.frame.minX
        frame.origin.y = window.frame.maxY - frame.height
        guard frame != window.frame else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        window.setFrame(frame, display: true, animate: animated && !reduceMotion)
    }
}

/// One tab's content, on its own so snapshots can render each tab without the window.
struct SettingsTabContent: View {
    let tab: SettingsTab
    @ObservedObject var navigation: SettingsNavigation
    /// Called when something that changes the tab's height changes, so the window can refit.
    var onLayoutChange: (() -> Void)?

    @EnvironmentObject private var model: AppModel
    @ObservedObject private var service = NotificationService.shared

    @MainActor
    init(tab: SettingsTab, navigation: SettingsNavigation? = nil, onLayoutChange: (() -> Void)? = nil) {
        self.tab = tab
        self.navigation = navigation ?? SettingsNavigation()
        self.onLayoutChange = onLayoutChange
    }

    /// Everything that can add, remove or rewrap rows while the window is open.
    private var layoutKey: SettingsLayoutKey {
        SettingsLayoutKey(authorization: service.authorization,
                          accountCount: model.accounts.count,
                          problemCount: model.accounts.filter { model.attentionMessage(for: $0) != nil }.count,
                          signInPhases: model.signInPhases,
                          isSigningInToMuse: model.isSigningInToMuse,
                          webSignInMessage: model.webSignInMessage,
                          isScanning: model.isScanning,
                          hasScanned: model.hasScanned,
                          launchAtLoginNeedsApproval: model.launchAtLoginNeedsApproval)
    }

    var body: some View {
        Group {
            switch tab {
            case .general: GeneralSettingsView()
            case .accounts: AccountsSettingsView(navigation: navigation)
            case .notifications: NotificationsSettingsView()
            }
        }
        .frame(width: SettingsTabViewController.contentWidth)
        .onChange(of: layoutKey) { _ in onLayoutChange?() }
    }
}

private struct SettingsLayoutKey: Equatable {
    var authorization: NotificationService.Authorization
    var accountCount: Int
    var problemCount: Int
    var signInPhases: [String: LoginPhase]
    var isSigningInToMuse: Bool
    var webSignInMessage: String?
    var isScanning: Bool
    var hasScanned: Bool
    var launchAtLoginNeedsApproval: Bool
}
