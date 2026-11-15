import SwiftUI
import AppKit
import TokenBarCore

/// Opens the first-launch setup window. Closing it in any way (Done, Esc, the close button) counts as
/// finishing the setup, and stops sign-ins started from it.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    static let contentSize = NSSize(width: 560, height: 460)

    private var window: NSWindow?
    private weak var model: AppModel?

    func show(model: AppModel) {
        self.model = model
        if window == nil {
            let host = NSHostingController(rootView: OnboardingView().environmentObject(model))
            host.sizingOptions = []
            let w = OnboardingWindow(contentRect: NSRect(origin: .zero, size: Self.contentSize),
                                     styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.contentViewController = host
            w.setContentSize(Self.contentSize)
            w.title = "Welcome to TokenBar"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.performClose(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        model?.completeOnboarding()
        model?.endOnboardingSession()
        closing.delegate = nil
        // A fresh window (back on the first page) next time it is opened.
        window = nil
    }
}

/// Esc closes the window like the close button does.
private final class OnboardingWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}
