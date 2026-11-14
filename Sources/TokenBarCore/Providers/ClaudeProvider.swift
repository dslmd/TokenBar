import Foundation

/// Claude Code. Source: `<config>/projects/**/*.jsonl` (includes `subagents/` logs).
///
/// Each assistant line carries `message.id`, `requestId`, `timestamp` and
/// `message.usage` {input_tokens, output_tokens, cache_creation_input_tokens,
/// cache_read_input_tokens}. Streaming writes the same message several times
/// with a growing `output_tokens`, and resumed sessions copy earlier history into
/// new files, so events are keyed by `message.id + requestId` and merged.
public struct ClaudeProvider: UsageProvider {
    public init() {}
    public let id = "claude"
    public let displayName = "Claude Code"
    public let symbolName = "sparkle"
    public let dataPathHint = "Claude Code 配置目录（含 projects 子目录），例如 ~/.claude；多账号可使用不同的 CLAUDE_CONFIG_DIR。"

    public func defaultDataPaths(environment: [String: String], home: URL) -> [String] {
        var paths: [String] = []
        if let env = environment["CLAUDE_CONFIG_DIR"], !env.isEmpty { paths.append(env) }
        paths.append(home.appendingPathComponent(".config/claude").path)
        paths.append(home.appendingPathComponent(".claude").path)
        return paths
    }

    public func scanRoots(forDataPath dataPath: String) -> [URL] {
        [URL(fileURLWithPath: dataPath).appendingPathComponent("projects")]
    }

    public func readMode(forFile url: URL) -> FileReadMode? {
        url.pathExtension == "jsonl" ? .lines : nil
    }

    public func makeParser(forFile url: URL) -> FileParser { ClaudeParser(fileName: url.lastPathComponent) }
}

final class ClaudeParser: FileParser {
    private let fileName: String
    init(fileName: String) { self.fileName = fileName }

    func consume(line: Data, offset: UInt64) -> ParseOutput {
        guard line.containsASCII("\"usage\""),
              let obj = JSON.object(line),
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let tsString = obj["timestamp"] as? String,
              let ts = ISO8601.parse(tsString) else { return .empty }

        let model = JSON.string(message["model"])
        if model == "<synthetic>" { return .empty }

        let tokens = TokenBreakdown(
            input: max(0, JSON.int(usage["input_tokens"])),
            output: max(0, JSON.int(usage["output_tokens"])),
            cacheRead: max(0, JSON.int(usage["cache_read_input_tokens"])),
            cacheWrite: max(0, JSON.int(usage["cache_creation_input_tokens"]))
        )
        if tokens.isZero { return .empty }

        let requestID = JSON.string(obj["requestId"]) ?? JSON.string(obj["request_id"])
        let key: String
        if let mid = JSON.string(message["id"]) {
            if let rid = requestID {
                key = "claude:\(mid):\(rid)"
            } else if let sid = JSON.string(obj["sessionId"]) {
                key = "claude:\(sid):\(mid)"
            } else {
                key = "claude:\(mid)"
            }
        } else {
            key = "claude:\(fileName)#\(offset)"
        }
        return ParseOutput(events: [UsageEvent(key: key, timestamp: ts, model: model, tokens: tokens)])
    }
}
