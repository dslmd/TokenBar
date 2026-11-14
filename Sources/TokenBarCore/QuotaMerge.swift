import Foundation

/// Combines quota found in local logs with online quota.
public enum QuotaMerge {
    /// Online data wins when present; local log data (Codex) is the fallback.
    public static func effective(local: QuotaObservation?, online: QuotaObservation?) -> (observation: QuotaObservation, isOnline: Bool)? {
        if let online, !online.windows.isEmpty { return (online, true) }
        if let local, !local.windows.isEmpty { return (local, false) }
        return nil
    }

    /// Highest used-percent among all current (not yet reset) windows, for the menu bar warning.
    public static func peakPercent(accounts: [Account], usage: [UUID: AccountUsage], quota: [UUID: QuotaResult],
                                   providerID: String? = nil, now: Date) -> Double? {
        var peak: Double?
        for a in accounts where providerID == nil || a.providerID == providerID {
            guard let e = effective(local: usage[a.id]?.quota, online: quota[a.id]?.observation) else { continue }
            for w in e.observation.windows where !w.isStale(at: now) {
                peak = max(peak ?? 0, w.usedPercent)
            }
        }
        return peak
    }
}

public enum PathValidation: Equatable, Sendable {
    case valid
    case missing
    case notADirectory
    case noLogsFound(expected: [String])

    public var message: String {
        switch self {
        case .valid: return "Logs found"
        case .missing: return "Folder not found"
        case .notADirectory: return "Not a folder"
        case .noLogsFound(let expected): return "No logs found. Expected \(expected.joined(separator: " or "))"
        }
    }
    public var isValid: Bool { self == .valid }
}

public extension UsageProvider {
    /// Checks whether a user-entered path looks like this provider's data directory.
    func validate(dataPath raw: String, fileManager: FileManager = .default) -> PathValidation {
        let path = expandPath(raw.trimmingCharacters(in: .whitespaces))
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir) else { return .missing }
        guard isDir.boolValue else { return .notADirectory }
        let roots = scanRoots(forDataPath: path)
        for root in roots {
            guard let en = fileManager.enumerator(at: root, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in true }) else { continue }
            var seen = 0
            for case let url as URL in en {
                seen += 1
                if readMode(forFile: url) != nil { return .valid }
                if seen > 5000 { break }
            }
        }
        let base = URL(fileURLWithPath: path).path
        let expected = roots.map { r -> String in
            r.path == base ? "session.jsonl" : (r.path.hasPrefix(base + "/") ? String(r.path.dropFirst(base.count + 1)) + "/" : r.path)
        }
        return .noLogsFound(expected: expected)
    }
}
