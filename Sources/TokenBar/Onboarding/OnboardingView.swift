import SwiftUI
import AppKit
import TokenBarCore

/// The first-launch setup: Welcome, Your accounts, Quota and notifications.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page: OnboardingPage
    @State private var movingForward = true

    /// - Parameter startPage: the page shown first (snapshots start on each page).
    init(startPage: OnboardingPage = .welcome) {
        _page = State(initialValue: startPage)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                pageContent
                    .id(page)
                    .transition(pageTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            if showsBottomDivider { Divider() }
            bottomBar
        }
        .frame(width: OnboardingWindowController.contentSize.width,
               height: OnboardingWindowController.contentSize.height)
    }

    /// The accounts list scrolls; a hairline keeps it from running into the buttons.
    private var showsBottomDivider: Bool {
        page == .accounts && model.onboardingStatus != .searching
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .welcome: OnboardingWelcomePage()
        case .accounts: OnboardingAccountsPage()
        case .alerts: OnboardingAlertsPage()
        }
    }

    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(insertion: .move(edge: movingForward ? .trailing : .leading).combined(with: .opacity),
                           removal: .move(edge: movingForward ? .leading : .trailing).combined(with: .opacity))
    }

    private var bottomBar: some View {
        ZStack {
            OnboardingPageDots(current: page) { go(to: $0) }
            HStack(spacing: 10) {
                Spacer()
                if let previous = page.previous {
                    Button("Back") { go(to: previous) }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                        .controlSize(.large)
                }
                Button {
                    if let next = page.next { go(to: next) } else { finish() }
                } label: {
                    Text(page.primaryButtonTitle).frame(minWidth: 64)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 18)
    }

    private func go(to target: OnboardingPage) {
        guard target != page else { return }
        movingForward = target.rawValue > page.rawValue
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { page = target }
    }

    private func finish() {
        model.completeOnboarding()
        OnboardingWindowController.shared.close()
    }
}

/// Page dots at the bottom center; each dot jumps to its page.
struct OnboardingPageDots: View {
    let current: OnboardingPage
    let select: (OnboardingPage) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingPage.allCases, id: \.self) { page in
                Button { select(page) } label: {
                    Circle()
                        .fill(page == current ? Color.primary.opacity(0.75) : Color.primary.opacity(0.2))
                        .frame(width: 7, height: 7)
                        .padding(3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(page.title)
                .accessibilityAddTraits(page == current ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Page \(current.rawValue + 1) of \(OnboardingPage.allCases.count)")
    }
}

/// Title and one line of explanation at the top of the accounts and quota pages.
struct OnboardingPageHeader: View {
    let title: String
    let subtitle: String
    var showsSpinner = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title2.weight(.semibold))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if showsSpinner {
                    ProgressView()
                        .controlSize(.small)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                }
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, OnboardingMetrics.formInset)
        .padding(.top, 8)
    }
}

enum OnboardingMetrics {
    /// Leading edge of a grouped form's sections, so text above a form lines up with it.
    static let formInset: CGFloat = 30
}

// MARK: - Welcome

struct OnboardingWelcomePage: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)
            OnboardingAppIcon()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("Welcome to TokenBar")
                .font(.system(size: 26, weight: .semibold))
                .padding(.top, 14)
            Text("Token use and quota for your AI coding tools, in the menu bar.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 18) {
                OnboardingFeatureRow(symbol: "person.crop.circle.badge.checkmark",
                                     title: "Finds your accounts",
                                     detail: "Claude Code, Codex, Gemini CLI, Muse and Muse Code accounts on this Mac are picked up automatically.")
                OnboardingFeatureRow(symbol: "bell.badge",
                                     title: "Warns before you hit a limit",
                                     detail: "A notification when a quota gets close, so it never runs out by surprise.")
                OnboardingFeatureRow(symbol: "internaldrive",
                                     title: "Reads logs on this Mac",
                                     detail: "Token counts come from each tool's own log files and never leave your Mac.")
            }
            .frame(width: 400)
            .padding(.top, 30)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 40)
    }
}

/// The app icon. Outside the app bundle (`swift run`, snapshots) macOS only has a generic folder
/// icon, so a drawn stand-in is used there.
struct OnboardingAppIcon: View {
    private var isAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    var body: some View {
        if isAppBundle {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
        } else {
            GeometryReader { proxy in
                let side = min(proxy.size.width, proxy.size.height) * 0.82
                RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.85), Color.accentColor],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(
                        Image(systemName: "chart.bar.fill")
                            .font(.system(size: side * 0.46, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                    .frame(width: side, height: side)
                    .shadow(color: .black.opacity(0.18), radius: side * 0.04, y: side * 0.02)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct OnboardingFeatureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundColor(.accentColor)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
