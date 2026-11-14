import AppKit
import WebKit
import TokenBarCore

/// What a successful Muse sign-in hands back to the app.
struct MuseSignInCredentials {
    /// `MuseAICookieSet.serialized()` output. Contains session cookies: store it only with
    /// `SecretStore.setSecret(_:for:)` (Keychain), never in config files or logs.
    let cookieSecret: String
    /// Email or name when the site exposes one. muse.ai's subscription response carries no identity,
    /// so this is currently always nil; callers should fall back to a default name.
    let accountLabel: String?
    /// Plan name ("Maximum", "Power", "Muse Free") when the verification fetch succeeded.
    let planName: String?
}

enum MuseSignInResult {
    case signedIn(MuseSignInCredentials)
    case cancelled
}

/// Signs in to muse.ai inside an app-owned web view, once per account.
///
/// Every attempt uses a fresh `WKWebsiteDataStore.nonPersistent()` (macOS 13 compatible), so
/// accounts never share cookies and nothing is left on disk by WebKit. Completion is detected
/// when muse.ai cookies exist and the server confirms the session (`GET https://muse.ai/` is not
/// redirected to auth.muse.ai, then a subscription fetch succeeds); the page URL and the
/// `hatch_sess` cookie hint only decide when to ask.
///
/// Usage:
/// ```
/// let controller = MuseSignInController()
/// controller.begin { result in ... }   // the controller keeps itself alive until it finishes
/// ```
@MainActor
final class MuseSignInController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
    static let startURL = URL(string: "https://muse.ai/")!

    private let fetcher: MuseAIFetcher
    private var window: NSWindow?
    private var webView: WKWebView?
    private var popups: [(window: NSWindow, webView: WKWebView)] = []
    private var completion: ((MuseSignInResult) -> Void)?
    /// Retains the controller while its window is open, so callers need not keep a reference.
    private var keepAlive: MuseSignInController?
    private var urlObservation: NSKeyValueObservation?
    private var checkTask: Task<Void, Never>?
    private var recheckRequested = false
    /// Cookie header that the server already rejected; not re-checked until the cookies change.
    private var rejectedHeader: String?
    private var finished = false
    private let statusLabel: NSTextField

    /// - Parameter fetcher: should share its action-id store with `MuseAIService` (the default
    ///   `MuseAIFetcher()` uses `UserDefaults.standard` and `MuseAIHTTPClient`, like the service default).
    init(fetcher: MuseAIFetcher = MuseAIFetcher()) {
        self.fetcher = fetcher
        // Created here rather than as a property default: AppKit views must be made on the main actor.
        statusLabel = NSTextField(labelWithString: "")
        super.init()
    }

    /// Brings an open sign-in window back to the front (used when "Sign in" is pressed again).
    func bringToFront() {
        guard !finished, let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Opens the sign-in window and brings the app to the front. `completion` is called exactly once
    /// on the main actor, with `.cancelled` if the user closes the window.
    func begin(completion: @escaping (MuseSignInResult) -> Void) {
        guard self.completion == nil, !finished else { return }
        self.completion = completion
        keepAlive = self

        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        // Some sign-in pages refuse unknown embedded browsers; present a Safari-style product token.
        config.applicationNameForUserAgent = "Version/16.6 Safari/605.1.15"

        let web = MuseSignInWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 680), configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.translatesAutoresizingMaskIntoConstraints = false
        webView = web
        config.websiteDataStore.httpCookieStore.add(self)
        urlObservation = web.observe(\.url, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.updateTitle() }
        }

        statusLabel.stringValue = "Sign in to your Muse account. This window closes when you are signed in."
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let reload = NSButton(title: "Reload", target: self, action: #selector(reloadPressed(_:)))

        let bar = NSStackView(views: [statusLabel, reload, cancel])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        bar.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 720))
        content.addSubview(web)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: content.topAnchor),
            web.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = content
        w.contentMinSize = NSSize(width: 400, height: 480)
        w.delegate = self
        w.center()
        window = w
        updateTitle()

        // Accessory app (no Dock icon): activate explicitly or the window opens behind others.
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()

        web.load(URLRequest(url: Self.startURL))
    }

    /// Closes the window and reports `.cancelled` (no effect after completion).
    func cancel() { finish(.cancelled) }

    @objc private func cancelPressed(_ sender: Any?) { cancel() }

    @objc private func reloadPressed(_ sender: Any?) {
        guard let web = webView else { return }
        if web.url == nil { web.load(URLRequest(url: Self.startURL)) } else { web.reload() }
    }

    // MARK: - Title

    private func updateTitle() {
        guard let window else { return }
        guard let url = webView?.url, let host = url.host, !host.isEmpty else {
            window.title = "Sign in to Muse"
            return
        }
        let secure = url.scheme?.lowercased() == "https"
        window.title = secure ? "Sign in to Muse – \(host)" : "Sign in to Muse – \(host) (not secure)"
    }

    // MARK: - Completion detection

    private func requestCheck() {
        guard !finished else { return }
        if checkTask != nil { recheckRequested = true; return }
        checkTask = Task { [weak self] in
            // Debounce: sign-in sets several cookies in quick succession.
            try? await Task.sleep(nanoseconds: 800_000_000)
            await self?.checkSignedIn()
            self?.checkDone()
        }
    }

    private func checkDone() {
        checkTask = nil
        if recheckRequested && !finished {
            recheckRequested = false
            requestCheck()
        }
    }

    private func checkSignedIn() async {
        guard !finished, let web = webView else { return }
        let cookies = await Self.allCookies(web.configuration.websiteDataStore.httpCookieStore)
        let set = MuseAICookieSet(httpCookies: cookies)
        guard !set.isEmpty, let header = set.cookieHeader(at: Date()), header != rejectedHeader else { return }

        // Only ask the server when there is a reason to: the main page finished loading on muse.ai
        // itself (signed-out visits are redirected to auth.muse.ai), or the session cookie hint appeared.
        let onSite = !web.isLoading && web.url?.host?.lowercased() == "muse.ai" && web.url?.scheme == "https"
        guard onSite || set.containsSessionHint else { return }

        statusLabel.stringValue = "Checking your Muse session…"
        let check = await fetcher.checkSession(cookieHeader: header)
        guard !finished else { return }
        if check == .signedOut {
            rejectedHeader = header
            statusLabel.stringValue = "Sign in to your Muse account. This window closes when you are signed in."
            return
        }

        // Confirm with the real request the app will make later.
        let result = await fetcher.fetch(cookieHeader: header)
        guard !finished else { return }
        switch result {
        case .success(let usage):
            complete(set, planName: usage.planName)
        case .failure(let failure) where failure.needsSignIn:
            rejectedHeader = header
            statusLabel.stringValue = "Sign in to your Muse account. This window closes when you are signed in."
        case .failure:
            // The page check passed but usage could not be read (site change or network). Accept the
            // session only when two independent signals agree, so the account can recover later.
            if check == .signedIn && onSite && set.containsSessionHint {
                complete(set, planName: nil)
            } else {
                statusLabel.stringValue = "Could not confirm the session yet. Finish signing in, or press Reload."
            }
        }
    }

    private func complete(_ set: MuseAICookieSet, planName: String?) {
        finish(.signedIn(MuseSignInCredentials(cookieSecret: set.serialized(), accountLabel: nil, planName: planName)))
    }

    /// The async form Swift imports for `getAllCookies(_:)` (available wherever that method is, macOS 10.13+).
    private static func allCookies(_ store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await store.allCookies()
    }

    private func finish(_ result: MuseSignInResult) {
        guard !finished else { return }
        finished = true
        checkTask?.cancel()
        checkTask = nil
        urlObservation?.invalidate()
        urlObservation = nil
        if let web = webView {
            web.configuration.websiteDataStore.httpCookieStore.remove(self)
            web.stopLoading()
            web.navigationDelegate = nil
            web.uiDelegate = nil
        }
        for p in popups {
            p.webView.stopLoading()
            p.webView.navigationDelegate = nil
            p.webView.uiDelegate = nil
            p.window.delegate = nil
            p.window.close()
        }
        popups.removeAll()
        if let window {
            window.delegate = nil
            window.close()
        }
        window = nil
        webView = nil
        let callback = completion
        completion = nil
        callback?(result)
        keepAlive = nil
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        if closing === window {
            finish(.cancelled)
        } else if let i = popups.firstIndex(where: { $0.window === closing }) {
            let p = popups.remove(at: i)
            p.webView.navigationDelegate = nil
            p.webView.uiDelegate = nil
            p.window.delegate = nil
        }
    }

    // MARK: - WKHTTPCookieStoreObserver

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in self?.requestCheck() }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === self.webView { updateTitle() }
        requestCheck()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showLoadError(error, in: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showLoadError(error, in: webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    private func showLoadError(_ error: Error, in webView: WKWebView) {
        guard webView === self.webView, !finished else { return }
        let ns = error as NSError
        // Cancelled loads (a newer navigation replaced this one) are not errors.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return } // frame load interrupted
        statusLabel.stringValue = "The page could not be loaded. Check your connection and press Reload."
    }

    // MARK: - WKUIDelegate (popups)

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard !finished else { return nil }
        // target=_blank links: open in the same view instead of silently doing nothing.
        if navigationAction.navigationType == .linkActivated {
            webView.load(navigationAction.request)
            return nil
        }
        // window.open (for example "Continue with" provider popups): give it a real child view that
        // shares this attempt's data store, so window.opener and postMessage keep working.
        let popupWeb = MuseSignInWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: configuration)
        popupWeb.navigationDelegate = self
        popupWeb.uiDelegate = self
        let width = windowFeatures.width.map { CGFloat($0.doubleValue) } ?? 480
        let height = windowFeatures.height.map { CGFloat($0.doubleValue) } ?? 640
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: max(320, width), height: max(320, height)),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.title = "Sign in to Muse"
        w.contentView = popupWeb
        w.delegate = self
        if let parent = window {
            let f = parent.frame
            w.setFrameTopLeftPoint(NSPoint(x: f.minX + 40, y: f.maxY - 40))
        } else {
            w.center()
        }
        popups.append((window: w, webView: popupWeb as WKWebView))
        w.makeKeyAndOrderFront(nil)
        return popupWeb
    }

    func webViewDidClose(_ webView: WKWebView) {
        if webView === self.webView {
            // The page closed itself; treat as cancellation only if nothing completed.
            finish(.cancelled)
        } else if let i = popups.firstIndex(where: { $0.webView === webView }) {
            let p = popups.remove(at: i)
            p.webView.navigationDelegate = nil
            p.webView.uiDelegate = nil
            p.window.delegate = nil
            p.window.close()
            requestCheck()
        }
    }
}

/// WKWebView that handles the standard editing shortcuts itself. TokenBar is an accessory app,
/// and without a visible Edit menu Command-V would otherwise not reach a password field.
final class MuseSignInWebView: WKWebView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command || flags == [.command, .shift], let key = event.charactersIgnoringModifiers?.lowercased() {
            let shift = flags.contains(.shift)
            var action: Selector?
            switch key {
            case "x" where !shift: action = #selector(NSText.cut(_:))
            case "c" where !shift: action = #selector(NSText.copy(_:))
            case "v" where !shift: action = #selector(NSText.paste(_:))
            case "a" where !shift: action = #selector(NSText.selectAll(_:))
            case "z": action = shift ? Selector(("redo:")) : Selector(("undo:"))
            default: action = nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}
