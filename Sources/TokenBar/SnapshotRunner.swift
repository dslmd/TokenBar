import SwiftUI
import AppKit
import TokenBarCore

/// Snapshot mode: `TokenBar --snapshot <output-dir>` renders the real views with demo data
/// (`DemoScenario`) to PNG files, in light and dark appearance, and exits.
///
/// Options:
///   --snapshot-scale <2|1|3|native>   pixels per point (default 2; `native` uses the display's scale)
///   --snapshot-only <text>            only shots whose name contains <text>
///
/// Each view is hosted in an offscreen borderless window and captured with AppKit's
/// `cacheDisplay(in:to:)`, so no Screen Recording or Accessibility permission is needed. Views taller
/// than their scroll area get extra pages (`-p2`, `-p3`, ...), scrolled down one screenful at a time.
/// The model is built with `AppModel(demo:)`: no accounts are looked for, no logs, Keychain or network.
@MainActor
enum SnapshotRunner {
    struct Shot {
        let name: String
        let scenario: DemoScenario
        /// Value for the popover's "collapsedProviders" setting.
        var collapsed: String = ""
        /// Tab to select in the first `NSTabView` found (settings).
        var tabIndex: Int?
        let content: () -> AnyView
    }

    static var shots: [Shot] {
        let popover: () -> AnyView = { AnyView(PopoverView()) }
        let settings: () -> AnyView = { AnyView(SettingsView()) }
        let menuBar: () -> AnyView = { AnyView(MenuBarSnapshot()) }
        return [
            Shot(name: "popover-rich", scenario: .rich, content: popover),
            Shot(name: "popover-rich-collapsed", scenario: .rich, collapsed: "claude,codex", content: popover),
            Shot(name: "popover-sparse", scenario: .sparse, content: popover),
            Shot(name: "popover-empty", scenario: .empty, content: popover),
            Shot(name: "popover-scanning", scenario: .scanning, content: popover),
            Shot(name: "popover-all-off", scenario: .allOff, content: popover),
            Shot(name: "popover-loading", scenario: .loading, content: popover),
            Shot(name: "settings-accounts-rich", scenario: .rich, content: settings),
            Shot(name: "settings-accounts-signing-in", scenario: .signingIn, content: settings),
            Shot(name: "settings-accounts-empty", scenario: .empty, content: settings),
            Shot(name: "settings-general-rich", scenario: .rich, tabIndex: 1, content: settings),
            Shot(name: "menubar-rich", scenario: .rich, content: menuBar),
            Shot(name: "menubar-sparse", scenario: .sparse, content: menuBar),
            Shot(name: "menubar-empty", scenario: .empty, content: menuBar),
        ]
    }

    static func run(outputDirectory: String, arguments: [String]) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        var scale: CGFloat? = 2
        if let value = option("--snapshot-scale", in: arguments) {
            if value == "native" {
                scale = nil
            } else if let number = Double(value), number >= 1, number <= 4 {
                scale = CGFloat(number)
            } else {
                say("Unknown --snapshot-scale value: \(value)")
                return 2
            }
        }
        let only = option("--snapshot-only", in: arguments)

        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            say("Cannot create \(directory.path): \(error.localizedDescription)")
            return 1
        }

        let version = ProcessInfo.processInfo.operatingSystemVersionString
        say("TokenBar snapshot mode, macOS \(version), scale \(scale.map { "\($0)" } ?? "native")")

        let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
        var index: [String] = []
        var problems = 0
        // One moment for the whole run, so every image shows the same times.
        let now = Date()
        for shot in shots where only == nil || shot.name.contains(only ?? "") {
            for (label, appearanceName) in appearances {
                guard let appearance = NSAppearance(named: appearanceName) else {
                    say("FAILED \(shot.name)-\(label): appearance not available")
                    problems += 1
                    continue
                }
                let result = capture(shot, appearance: appearance, scale: scale, now: now)
                problems += result.problems
                if result.pages.isEmpty {
                    say("FAILED \(shot.name)-\(label): nothing was rendered")
                    problems += 1
                }
                for (page, rep) in result.pages.enumerated() {
                    let file = "\(shot.name)-\(label)" + (page == 0 ? "" : "-p\(page + 1)") + ".png"
                    guard let png = rep.representation(using: .png, properties: [:]) else {
                        say("FAILED \(file): PNG encoding failed")
                        problems += 1
                        continue
                    }
                    do {
                        try png.write(to: directory.appendingPathComponent(file))
                    } catch {
                        say("FAILED \(file): \(error.localizedDescription)")
                        problems += 1
                        continue
                    }
                    var line = "\(file)\t\(rep.pixelsWide)x\(rep.pixelsHigh) px\t\(Int(rep.size.width))x\(Int(rep.size.height)) pt"
                    if isBlank(rep) {
                        line += "\tBLANK"
                        problems += 1
                    }
                    say(line)
                    index.append(line)
                }
            }
        }
        if index.isEmpty {
            say("No snapshots were written.")
            return 1
        }
        try? Data((index.joined(separator: "\n") + "\n").utf8).write(to: directory.appendingPathComponent("index.txt"))
        say("\(index.count) snapshots written to \(directory.path), \(problems) problem(s)")
        return problems == 0 ? 0 : 1
    }

    // MARK: One shot

    private static func capture(_ shot: Shot, appearance: NSAppearance, scale: CGFloat?, now: Date) -> (pages: [NSBitmapImageRep], problems: Int) {
        // The argument domain is volatile (never written to disk) and is searched first, so the
        // popover's remembered "collapsed" state neither leaks into the snapshot nor gets changed.
        UserDefaults.standard.setVolatileDomain(["collapsedProviders": shot.collapsed], forName: UserDefaults.argumentDomain)
        NSApp.appearance = appearance

        let model = AppModel(demo: shot.scenario.state(now: now, home: NSHomeDirectory()))
        let root = shot.content()
            .environmentObject(model)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: AnyView(root))
        host.appearance = appearance
        // The view's ideal size, as a window sized to its content would get. Measured before the automatic
        // sizing constraints are switched off (without them the hosting view reports no size at all).
        host.layoutSubtreeIfNeeded()
        var ideal = host.intrinsicContentSize
        if ideal.width < 1 || ideal.height < 1 { ideal = host.fittingSize }
        host.sizingOptions = []
        guard ideal.width >= 1, ideal.height >= 1, ideal.width < 4000, ideal.height < 8000 else {
            say("FAILED \(shot.name): the view reported an unusable size \(ideal)")
            return ([], 1)
        }
        let size = NSSize(width: ideal.width.rounded(.up), height: ideal.height.rounded(.up))

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.appearance = appearance
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)

        let window = SnapshotWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = container
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        settle()
        // Overlay scrollers, as on a Mac with a trackpad (a runner without one shows fixed scroll bars).
        for scroll in descendants(of: container, as: NSScrollView.self) where scroll.scrollerStyle != .overlay {
            scroll.scrollerStyle = .overlay
        }
        settle()

        var problems = 0
        if let tab = shot.tabIndex {
            if let tabs = descendants(of: container, as: NSTabView.self).first, tab < tabs.numberOfTabViewItems {
                tabs.selectTabViewItem(at: tab)
                settle()
            } else {
                say("FAILED \(shot.name): no tab view with a tab \(tab) was found")
                problems += 1
            }
        }

        var pages: [NSBitmapImageRep] = []
        if let first = bitmap(of: container, scale: scale, appearance: appearance) { pages.append(first) }

        // Extra pages for the tallest scroll area that does not show all of its content.
        let scrollable = descendants(of: container, as: NSScrollView.self).compactMap { scroll -> (NSScrollView, CGFloat, CGFloat)? in
            guard let document = scroll.documentView else { return nil }
            let visible = scroll.contentView.bounds.height
            let total = document.frame.height
            return visible > 60 && total > visible + 1 ? (scroll, visible, total) : nil
        }
        if let (scroll, visible, total) = scrollable.max(by: { $0.2 < $1.2 }), let document = scroll.documentView {
            let last = total - visible
            let step = max(60, visible - 48)
            var offset: CGFloat = 0
            while offset < last && pages.count < 8 {
                offset = min(last, offset + step)
                let y = document.isFlipped ? offset : last - offset
                scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                settle()
                if let page = bitmap(of: container, scale: scale, appearance: appearance) { pages.append(page) }
            }
        }
        return (pages, problems)
    }

    /// Lets SwiftUI finish layout, `onAppear` work and pending drawing.
    private static func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        CATransaction.flush()
    }

    private static func bitmap(of view: NSView, scale: CGFloat?, appearance: NSAppearance) -> NSBitmapImageRep? {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bounds = view.bounds
        let rep: NSBitmapImageRep?
        if let scale {
            rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int((bounds.width * scale).rounded()),
                                   pixelsHigh: Int((bounds.height * scale).rounded()),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            // Point size smaller than the pixel size makes AppKit draw at that scale.
            rep?.size = bounds.size
        } else {
            rep = view.bitmapImageRepForCachingDisplay(in: bounds)
        }
        guard let rep else { return nil }
        // AppKit controls that draw themselves (tab bar, buttons) follow the current drawing appearance,
        // not the view's, when drawn into a bitmap.
        appearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: bounds, to: rep)
        }
        return rep
    }

    /// True when every sampled pixel has the same colour, i.e. nothing was drawn.
    private static func isBlank(_ rep: NSBitmapImageRep) -> Bool {
        guard let data = rep.bitmapData else { return true }
        let bytesPerPixel = max(1, rep.bitsPerPixel / 8)
        let stepX = max(1, rep.pixelsWide / 96)
        let stepY = max(1, rep.pixelsHigh / 96)
        var y = 0
        while y < rep.pixelsHigh {
            var x = 0
            while x < rep.pixelsWide {
                let offset = y * rep.bytesPerRow + x * bytesPerPixel
                for byte in 0..<bytesPerPixel where data[offset + byte] != data[byte] { return false }
                x += stepX
            }
            y += stepY
        }
        return true
    }

    private static func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        var found: [T] = []
        for child in view.subviews {
            if let match = child as? T { found.append(match) }
            found.append(contentsOf: descendants(of: child, as: type))
        }
        return found
    }

    private static func option(_ name: String, in arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    private static func say(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

/// An offscreen window whose controls draw as in the frontmost window (accent-coloured switches and
/// checkboxes) although it never becomes key.
private final class SnapshotWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The menu bar label on a plain strip, at the menu bar's text size.
private struct MenuBarSnapshot: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        MenuBarLabel(model: model)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 24)
    }
}
