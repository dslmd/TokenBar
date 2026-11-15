import SwiftUI
import AppKit

/// Reports when the window hosting the menu bar content opens (becomes key) and closes (resigns key).
/// A MenuBarExtra window keeps its SwiftUI tree between openings, and `onAppear` is not reliable for
/// every opening, so the popover watches its window instead.
struct PopoverWindowObserver: NSViewRepresentable {
    let onOpen: () -> Void
    let onClose: () -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onOpen = onOpen
        view.onClose = onClose
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onOpen = onOpen
        view.onClose = onClose
    }

    final class ObserverView: NSView {
        var onOpen: (() -> Void)?
        var onClose: (() -> Void)?
        private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            guard let window else { return }
            let center = NotificationCenter.default
            tokens.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.onOpen?()
            })
            tokens.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.onClose?()
            })
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        deinit {
            tokens.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
