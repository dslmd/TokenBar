import Foundation

/// OpenAI Codex CLI. Source: `<CODEX_HOME>/sessions/YYYY/MM/DD/rollout-*.jsonl`
/// and `<CODEX_HOME>/archived_sessions/*.jsonl`.
///
/// Lines look like `{"timestamp":…,"type":"event_msg","payload":{"type":"token_count",
/// "info":{"total_token_usage":{…},"last_token_usage":{…}},"rate_limits":{…}}}`.
/// `total_token_usage` is cumulative for the session, so per-call usage is the
/// difference between consecutive totals; `turn_context` lines carry the model.
public struct CodexProvider: UsageProvider {
    public init() {}
    public let id = "codex"
    public let displayName = "Codex"
    public let symbolName = "terminal"
    public let dataPathHint = "Codex 主目录（含 sessions 子目录），例如 ~/.codex；多账号可使用不同的 CODEX_HOME。"

    public func defaultDataPaths(environment: [String: String], home: URL) -> [String] {
        var paths: [String] = []
        if let env = environment["CODEX_HOME"], !env.isEmpty { paths.append(env) }
        paths.append(home.appendingPathComponent(".codex").path)
        return paths
    }

    public func scanRoots(forDataPath dataPath: String) -> [URL] {
        let base = URL(fileURLWithPath: dataPath)
        return [base.appendingPathComponent("sessions"), base.appendingPathComponent("archived_sessions")]
    }

    public func readMode(forFile url: URL) -> FileReadMode? {
        url.pathExtension == "jsonl" ? .lines : nil
    }

    public func makeParser(forFile url: URL) -> FileParser { CodexParser(fileName: url.lastPathComponent) }
}

final class CodexParser: FileParser {
    private struct Raw: Equatable {
        var input = 0, cached = 0, output = 0, cacheWrite = 0
        init(_ d: [String: Any]) {
            input = max(0, JSON.int(d["input_tokens"]))
            cached = max(0, JSON.int(d["cached_input_tokens"]))
            output = max(0, JSON.int(d["output_tokens"]))
            cacheWrite = max(0, JSON.int(d["cache_write_input_tokens"]))
        }
        func atLeast(_ o: Raw) -> Bool {
            input >= o.input && cached >= o.cached && output >= o.output && cacheWrite >= o.cacheWrite
        }
        func minus(_ o: Raw) -> Raw {
            var r = self
            r.input -= o.input; r.cached -= o.cached; r.output -= o.output; r.cacheWrite -= o.cacheWrite
            return r
        }
        var isZero: Bool { input == 0 && cached == 0 && output == 0 && cacheWrite == 0 }
        var breakdown: TokenBreakdown {
            // OpenAI semantics: cached tokens are a subset of input; reasoning is a subset of output.
            TokenBreakdown(input: max(0, input - cached), output: output, cacheRead: min(cached, input), cacheWrite: cacheWrite)
        }
        private init() {}
    }

    private let fileName: String
    private var previousTotal: Raw?
    private var model: String?

    init(fileName: String) { self.fileName = fileName }

    func consume(line: Data, offset: UInt64) -> ParseOutput {
        let isContext = line.containsASCII("turn_context")
        let isCount = line.containsASCII("token_count")
        guard isContext || isCount, let obj = JSON.object(line),
              let type = obj["type"] as? String,
              let payload = obj["payload"] as? [String: Any] else { return .empty }

        if type == "turn_context" {
            if let m = JSON.string(payload["model"]) { model = m }
            return .empty
        }
        guard type == "event_msg", payload["type"] as? String == "token_count",
              let ts = (obj["timestamp"] as? String).flatMap(ISO8601.parse) else { return .empty }

        var out = ParseOutput()
        if let rl = payload["rate_limits"] as? [String: Any] {
            let windows = Self.quotaWindows(from: rl, observedAt: ts)
            if !windows.isEmpty { out.quota = QuotaObservation(observedAt: ts, windows: windows) }
        }

        guard let info = payload["info"] as? [String: Any] else { return out }
        let total = (info["total_token_usage"] as? [String: Any]).map(Raw.init)
        let last = (info["last_token_usage"] as? [String: Any]).map(Raw.init)

        var delta: Raw?
        if let total {
            if let prev = previousTotal {
                if total == prev {
                    delta = nil                       // repeated snapshot
                } else if total.atLeast(prev) {
                    delta = total.minus(prev)         // normal cumulative growth
                } else {
                    delta = last ?? total             // counter reset
                }
            } else {
                // First snapshot in this file. Forked/resumed rollouts inherit the parent's
                // cumulative total, so prefer the per-call figure when present.
                delta = last ?? total
            }
            previousTotal = total
        } else {
            delta = last
        }

        if let delta, !delta.isZero {
            out.events.append(UsageEvent(key: "codex:\(fileName)#\(offset)", timestamp: ts, model: model, tokens: delta.breakdown))
        }
        return out
    }

    static func quotaWindows(from rl: [String: Any], observedAt: Date) -> [QuotaWindow] {
        var windows: [QuotaWindow] = []
        for (name, fallback) in [("primary", "主要窗口"), ("secondary", "次要窗口")] {
            guard let w = rl[name] as? [String: Any], let used = JSON.double(w["used_percent"]) else { continue }
            let minutes = (w["window_minutes"] ?? w["limit_window_minutes"]).map { JSON.int($0) }.flatMap { $0 > 0 ? $0 : nil }
            var reset: Date?
            if let secs = JSON.int64(w["resets_at"]), secs > 0 {
                reset = Date(timeIntervalSince1970: TimeInterval(secs))
            } else if let rel = JSON.int64(w["resets_in_seconds"]), rel >= 0 {
                reset = observedAt.addingTimeInterval(TimeInterval(rel))
            }
            windows.append(QuotaWindow(label: windowLabel(minutes: minutes, fallback: fallback),
                                       usedPercent: min(100, max(0, used)), windowMinutes: minutes, resetsAt: reset))
        }
        return windows
    }

    static func windowLabel(minutes: Int?, fallback: String) -> String {
        guard let m = minutes else { return fallback }
        if m == 10080 { return "每周" }
        if m % 1440 == 0 { return "\(m / 1440) 天" }
        if m % 60 == 0 { return "\(m / 60) 小时" }
        return "\(m) 分钟"
    }
}
