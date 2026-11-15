import SwiftUI
import AppKit
import TokenBarCore

/// Opens the first-launch setup window. Placeholder until the onboarding is built.
@MainActor
final class OnboardingWindowController {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?

    func show(model: AppModel) {
        if window == nil {
            let host = NSHostingController(rootView: OnboardingView().environmentObject(model))
            let w = NSWindow(contentViewController: host)
            w.title = "Welcome to TokenBar"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }
}

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            Text("Welcome to TokenBar").font(.title2.weight(.semibold))
            Button("Done") {
                model.completeOnboarding()
                OnboardingWindowController.shared.close()
            }
        }
        .padding(40)
        .frame(width: 520)
    }
}
