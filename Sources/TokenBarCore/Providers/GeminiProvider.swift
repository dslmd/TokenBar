import Foundation

/// Gemini CLI. Source: `<gemini home>/tmp/<project id>/chats/**/session-*.jsonl`
/// (current, append-only) and the legacy `session-*.json` single-document format.
///
/// Gemini messages (`type == "gemini"`) carry `tokens` {input, output, cached,
/// thoughts, tool, total} mirroring the API's usageMetadata. `input` (promptTokenCount)
/// already includes the cached portion. The local files hold no quota information.
public struct GeminiProvider: UsageProvider {
    public init() {}
    public let id = "gemini"
    public let displayName = "Gemini CLI"
    public let symbolName = "diamond"
    public let dataPathHint = "Gemini CLI folder (contains tmp), usually ~/.gemini, or $GEMINI_CLI_HOME/.gemini."

    public func defaultDataPaths(environment: [String: String], home: URL) -> [String] {
        [home.appendingPathComponent(".gemini").path]
    }

    public func scanRoots(forDataPath dataPath: String) -> [URL] {
        [URL(fileURLWithPath: dataPath).appendingPathComponent("tmp")]
    }

    public func readMode(forFile url: URL) -> FileReadMode? {
        let name = url.lastPathComponent
        guard name.hasPrefix("session-"), url.path.contains("/chats/") else { return nil }
        switch url.pathExtension {
        case "jsonl": return .lines
        case "json": return .wholeFile
        default: return nil
        }
    }

    public func makeParser(forFile url: URL) -> FileParser {
        GeminiParser(fallbackSessionID: url.deletingPathExtension().lastPathComponent)
    }
}

final class GeminiParser: FileParser {
    private var sessionID: String

    init(fallbackSessionID: String) { sessionID = fallbackSessionID }

    func consume(line: Data, offset: UInt64) -> ParseOutput {
        guard line.containsASCII("\"tokens\""), let obj = JSON.object(line) else {
            // Metadata lines may still name the session even without tokens.
            if line.containsASCII("\"sessionId\""), let obj = JSON.object(line), let sid = JSON.string(obj["sessionId"]) {
                sessionID = sid
            }
            return .empty
        }
        return process(record: obj)
    }

    func consume(document: Data) -> ParseOutput {
        guard let obj = JSON.object(document) else { return .empty }
        return process(record: obj)
    }

    private func process(record obj: [String: Any]) -> ParseOutput {
        if let sid = JSON.string(obj["sessionId"]) { sessionID = sid }
        var out = ParseOutput()
        if let set = obj["$set"] as? [String: Any], let msgs = set["messages"] as? [[String: Any]] {
            for m in msgs { append(message: m, to: &out) }
        } else if let msgs = obj["messages"] as? [[String: Any]] {
            for m in msgs { append(message: m, to: &out) }
        } else {
            append(message: obj, to: &out)
        }
        return out
    }

    private func append(message m: [String: Any], to out: inout ParseOutput) {
        guard m["type"] as? String == "gemini",
              let id = JSON.string(m["id"]),
              let t = m["tokens"] as? [String: Any],
              let ts = (m["timestamp"] as? String).flatMap(ISO8601.parse) else { return }
        let prompt = max(0, JSON.int(t["input"]))
        let cached = min(max(0, JSON.int(t["cached"])), prompt)
        let tokens = TokenBreakdown(
            input: prompt - cached + max(0, JSON.int(t["tool"])),
            output: max(0, JSON.int(t["output"])) + max(0, JSON.int(t["thoughts"])),
            cacheRead: cached,
            cacheWrite: 0
        )
        if tokens.isZero { return }
        out.events.append(UsageEvent(key: "gemini:\(sessionID):\(id)", timestamp: ts, model: JSON.string(m["model"]), tokens: tokens))
    }
}
