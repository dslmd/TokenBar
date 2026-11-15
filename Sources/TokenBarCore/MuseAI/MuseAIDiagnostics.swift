import Foundation

/// Step-by-step report of the muse.ai fetch, for finding out why reading usage fails on the real site
/// (`TokenBar --diagnose-muse`). It reports only structure: HTTP statuses, sizes, which patterns match,
/// short excerpts of the public JavaScript files (fetched without cookies) and the key names and value
/// types of the action's answer. It never prints cookie values, cookie names' values or response values.
public enum MuseAIDiagnostics {
    public static func run(cookies: MuseAICookieSet, http: HTTPClient = MuseAIHTTPClient(),
                           cachedActionID: String?, now: Date = Date()) async -> [String] {
        var out: [String] = []
        out.append("cookies: \(cookies.cookies.count) (expired: \(cookies.isExpired(at: now)))")
        guard let header = cookies.cookieHeader(at: now) else {
            out.append("no usable cookie header")
            return out
        }

        // 1. The signed-in page.
        let page: HTTPResponse
        do {
            page = try await http.send(HTTPRequest(url: MuseAIFetcher.rootURL,
                                                   headers: ["Cookie": header, "Accept": "text/html", "User-Agent": MuseAIFetcher.userAgent],
                                                   timeout: 20))
        } catch {
            out.append("page: transport error")
            return out
        }
        out.append("page: HTTP \(page.status), \(page.body.count) bytes")
        if (300..<400).contains(page.status) {
            let location = String(decoding: page.body.prefix(512), as: UTF8.self)
            out.append("page redirect host: \(URL(string: location)?.host ?? "?")")
            return out
        }
        let html = String(decoding: page.body, as: UTF8.self)
        let paths = MuseAIDiscovery.chunkPaths(in: html)
        out.append("page chunk paths (static/chunks/*.js): \(paths.count)")
        out.append("page mentions: _next \(count("_next/", in: html)), fetchSubscription \(count("fetchSubscription", in: html)), Settings \(count("Settings", in: html))")
        if paths.isEmpty {
            out.append("page script srcs: " + MuseAIRegex.matches(#"<script[^>]+src="([^"]+)""#, in: html).prefix(8)
                .map { shorten($0, 90) }.joined(separator: " | "))
        }

        // 2. The public JavaScript files the page loads (no cookies).
        var chunkTexts: [(String, String)] = []
        for path in paths.prefix(120) {
            guard let url = URL(string: MuseAIFetcher.origin + path),
                  let r = try? await http.send(HTTPRequest(url: url, headers: ["Accept": "*/*", "User-Agent": MuseAIFetcher.userAgent], timeout: 20)),
                  r.status == 200 else { continue }
            chunkTexts.append((path, String(decoding: r.body, as: UTF8.self)))
        }
        out.append("page chunks fetched: \(chunkTexts.count), total \(chunkTexts.reduce(0) { $0 + $1.1.utf8.count }) bytes")
        var all = chunkTexts.map(\.1).joined(separator: "\n")
        let loader = MuseAIDiscovery.settingsLoaderList(in: all)
        out.append("settings loader list found: \(loader != nil)")
        if let loader {
            let settingsPaths = MuseAIDiscovery.chunkPaths(in: loader)
            out.append("settings loader list: \(loader.count) chars, \(settingsPaths.count) chunk paths; starts: \(shorten(loader, 120))")
            for path in settingsPaths.prefix(40) {
                guard let url = URL(string: MuseAIFetcher.origin + path),
                      let r = try? await http.send(HTTPRequest(url: url, headers: ["Accept": "*/*", "User-Agent": MuseAIFetcher.userAgent], timeout: 20)),
                      r.status == 200 else { out.append("  settings chunk failed: \(shorten(path, 60))"); continue }
                chunkTexts.append((path, String(decoding: r.body, as: UTF8.self)))
            }
        }
        all = chunkTexts.map(\.1).joined(separator: "\n")
        out.append("'.A(<n>).then(({...Settings' matches: \(MuseAIRegex.matches(#"\.A\((\d+)\)\.then\(\(\{[^}]*Settings"#, in: all).count)")
        out.append("createServerReference in page chunks: \(count("createServerReference", in: all)), fetchSubscriptionAction: \(count("fetchSubscriptionAction", in: all))")
        for (path, text) in chunkTexts {
            for needle in ["fetchSubscriptionAction", "preloadHatchSettings", "Settings"] where needle != "Settings" || count("fetchSubscription", in: text) > 0 {
                for snippet in excerpts(of: needle, in: text, limit: 2) {
                    out.append("  \(shorten(path, 60)) [\(needle)]: \(snippet)")
                }
            }
        }
        // Names of things that look like server actions, to spot a renamed action.
        let actionNames = Set(MuseAIRegex.matches(#""([A-Za-z]*(?:Subscription|Usage|Quota|Billing)[A-Za-z]*Action)""#, in: all))
        out.append("action-like names: \(actionNames.sorted().prefix(20).joined(separator: ", "))")

        // 3. The action itself, with the id found now or the cached one.
        var ids: [(String, String)] = []
        if let found = MuseAIDiscovery.actionID(in: all) { ids.append(("discovered", found)) }
        if let cachedActionID, !ids.contains(where: { $0.1 == cachedActionID }) { ids.append(("cached", cachedActionID)) }
        if ids.isEmpty { out.append("no action id available") }
        for (source, id) in ids {
            out.append("action id (\(source)): \(id.count) hex chars")
            let req = HTTPRequest(url: MuseAIFetcher.rootURL, method: "POST", headers: [
                "Cookie": header, "Accept": "text/x-component", "Next-Action": id, "Origin": MuseAIFetcher.origin,
                "Sec-Fetch-Site": "same-origin", "Sec-Fetch-Mode": "cors", "Sec-Fetch-Dest": "empty",
                "Content-Type": "text/plain;charset=UTF-8", "User-Agent": MuseAIFetcher.userAgent,
            ], body: MuseAIFetcher.actionBody, timeout: 20)
            guard let r = try? await http.send(req) else { out.append("  action: transport error"); continue }
            out.append("  action: HTTP \(r.status), \(r.body.count) bytes")
            out.append(contentsOf: describeFlight(r.body).map { "  " + $0 })
            out.append("  parser result: \(MuseAIResponseParser.parse(r.body, observedAt: now) == nil ? "nil" : "usage")")
        }
        return out
    }

    /// Row prefixes and the shape (keys and value types, never values) of each JSON row.
    static func describeFlight(_ body: Data) -> [String] {
        var out: [String] = []
        let lines = String(decoding: body, as: UTF8.self).components(separatedBy: .newlines).filter { !$0.isEmpty }
        out.append("rows: \(lines.count)")
        for line in lines.prefix(12) {
            let prefix = line.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
            let rest = line.dropFirst(min(line.count, prefix.count + 1))
            if let data = rest.data(using: .utf8), let json = try? JSONDecoder().decode(MuseAIJSON.self, from: data) {
                out.append("row \(shorten(prefix, 12)): \(shape(json, depth: 0))")
            } else {
                out.append("row \(shorten(prefix, 12)): not JSON, \(rest.count) chars, starts with \(shorten(String(rest.prefix(1)), 4))")
            }
        }
        return out
    }

    static func shape(_ value: MuseAIJSON, depth: Int) -> String {
        switch value {
        case .null: return "null"
        case .bool: return "bool"
        case .number: return "number"
        case .string: return "string"
        case .array(let items):
            guard let first = items.first, depth < 4 else { return "[\(items.count)]" }
            return "[\(items.count) x \(shape(first, depth: depth + 1))]"
        case .object(let obj):
            guard depth < 4 else { return "{\(obj.count) keys}" }
            return "{" + obj.keys.sorted().prefix(24).map { "\($0): \(shape(obj[$0]!, depth: depth + 1))" }.joined(separator: ", ") + "}"
        }
    }

    static func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// Up to `limit` excerpts of 160 characters around `needle`, long hex strings shortened.
    static func excerpts(of needle: String, in text: String, limit: Int) -> [String] {
        var out: [String] = []
        var searchRange = text.startIndex..<text.endIndex
        while out.count < limit, let r = text.range(of: needle, range: searchRange) {
            let start = text.index(r.lowerBound, offsetBy: -100, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(r.upperBound, offsetBy: 60, limitedBy: text.endIndex) ?? text.endIndex
            var snippet = String(text[start..<end]).replacingOccurrences(of: "\n", with: " ")
            if let regex = try? NSRegularExpression(pattern: "[0-9a-f]{40,}") {
                snippet = regex.stringByReplacingMatches(in: snippet, range: NSRange(snippet.startIndex..., in: snippet), withTemplate: "<hex>")
            }
            out.append(snippet)
            searchRange = r.upperBound..<text.endIndex
        }
        return out
    }

    static func shorten(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n)) + "..."
    }
}
