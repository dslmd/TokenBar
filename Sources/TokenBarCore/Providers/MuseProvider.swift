import Foundation

/// Muse Code (Meta's terminal coding agent). Closed source; the on-disk layout is
/// documented only by third-party tools (CodexBar, tokscale, agentsview).
///
/// Source: `<sessions dir>/YYYY/MM/DD/<session id>/session.jsonl` plus
/// `…/subagent/<child id>/session.jsonl`. Each line is an event envelope
/// `{"recorded_at":<µs>,"stream":{"id":…},"sequence":n,"payload":{"event":{"kind":
/// "model_completed","model":…,"usage":{input_tokens,output_tokens,cached_tokens,
/// cache_write_tokens,reasoning_tokens}}}}`. Cached tokens are a subset of input and
/// reasoning tokens a subset of output. The subscription quota is only available from a
/// private Meta endpoint that needs the CLI's OAuth token, which TokenBar deliberately
/// does not call.
public struct MuseProvider: UsageProvider {
    public init() {}
    public let id = "muse"
    public let displayName = "Muse Code"
    public let symbolName = "wand.and.stars"
    public let dataPathHint = "Muse Code (the coding CLI) sessions folder, default ~/.local/share/muse/sessions (or $XDG_DATA_HOME/muse/sessions, $MUSE_SESSIONS_DIR). This is not the Muse personal assistant. The log format is not published by Meta."

    public func defaultDataPaths(environment: [String: String], home: URL) -> [String] {
        var paths: [String] = []
        if let env = environment["MUSE_SESSIONS_DIR"], !env.isEmpty { paths.append(env) }
        if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            paths.append(URL(fileURLWithPath: xdg).appendingPathComponent("muse/sessions").path)
        }
        paths.append(home.appendingPathComponent(".local/share/muse/sessions").path)
        return paths
    }

    public func scanRoots(forDataPath dataPath: String) -> [URL] { [URL(fileURLWithPath: dataPath)] }

    public func readMode(forFile url: URL) -> FileReadMode? {
        url.lastPathComponent == "session.jsonl" ? .lines : nil
    }

    public func makeParser(forFile url: URL) -> FileParser {
        MuseParser(fallbackStream: url.deletingLastPathComponent().lastPathComponent)
    }
}

final class MuseParser: FileParser {
    private let fallbackStream: String
    init(fallbackStream: String) { self.fallbackStream = fallbackStream }

    func consume(line: Data, offset: UInt64) -> ParseOutput {
        let hasUsage = line.containsASCII("model_completed") || line.containsASCII("automated_review_completed")
        guard hasUsage, let obj = JSON.object(line) else { return .empty }

        var out = ParseOutput()
        if let children = obj["children"] as? [[String: Any]], obj["retained_frame"] != nil {
            // Retained frames wrap full records as JSON strings.
            for (i, child) in children.enumerated() {
                guard let raw = child["record_json"] as? String,
                      let inner = JSON.object(Data(raw.utf8)) else { continue }
                if let e = event(from: inner, fallbackKey: "\(fallbackStream)#\(offset)#\(i)") { out.events.append(e) }
            }
        } else if let e = event(from: obj, fallbackKey: "\(fallbackStream)#\(offset)") {
            out.events.append(e)
        }
        return out
    }

    private func event(from obj: [String: Any], fallbackKey: String) -> UsageEvent? {
        guard let payload = obj["payload"] as? [String: Any],
              let ev = payload["event"] as? [String: Any],
              let kind = ev["kind"] as? String,
              kind == "model_completed" || kind == "automated_review_completed",
              let usage = ev["usage"] as? [String: Any],
              let rawTs = JSON.int64(obj["recorded_at"]), let ts = Self.date(fromRecordedAt: rawTs) else { return nil }

        let input = max(0, JSON.int(usage["input_tokens"]))
        let cacheRead = min(input, max(0, JSON.int(usage["cache_read_tokens"] ?? usage["cached_tokens"])))
        let tokens = TokenBreakdown(
            input: input - cacheRead,
            output: max(0, JSON.int(usage["output_tokens"])),
            cacheRead: cacheRead,
            cacheWrite: max(0, JSON.int(usage["cache_write_tokens"]))
        )
        if tokens.isZero { return nil }

        let stream = ((obj["stream"] as? [String: Any]).flatMap { JSON.string($0["id"]) }) ?? fallbackStream
        let key: String
        if let seq = JSON.int64(obj["sequence"]) { key = "muse:\(stream):\(seq)" } else { key = "muse:\(fallbackKey)" }
        return UsageEvent(key: key, timestamp: ts, model: JSON.string(ev["model"]), tokens: tokens)
    }

    /// `recorded_at` is microseconds today; accept ms and s defensively.
    static func date(fromRecordedAt raw: Int64) -> Date? {
        if raw >= 1_000_000_000_000_000 { return Date(timeIntervalSince1970: Double(raw) / 1_000_000) }
        if raw >= 1_000_000_000_000 { return Date(timeIntervalSince1970: Double(raw) / 1000) }
        if raw >= 1_000_000_000 { return Date(timeIntervalSince1970: Double(raw)) }
        return nil
    }
}
