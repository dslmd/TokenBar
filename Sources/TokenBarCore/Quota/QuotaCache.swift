import Foundation

/// The last successfully read online quota per account, kept on disk so TokenBar can still show it after a
/// relaunch while the CLI's sign-in waits to be renewed. Holds only percentages, reset times and the time of
/// the reading: nothing secret.
public struct QuotaCache: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var observedAt: Date
        public var windows: [QuotaWindow]
        public init(observedAt: Date, windows: [QuotaWindow]) {
            self.observedAt = observedAt
            self.windows = windows
        }
    }

    /// Readings older than this are not shown any more (every window has long reset by then).
    public static let maxAge: TimeInterval = 8 * 86400

    public var entries: [UUID: Entry]

    public init(entries: [UUID: Entry] = [:]) { self.entries = entries }

    /// Remembers every fresh reading in `results`, forgets accounts that no longer exist and old readings.
    public mutating func record(_ results: [UUID: QuotaResult], existing: Set<UUID>, now: Date) {
        for (id, result) in results {
            if let observation = result.observation, !observation.windows.isEmpty {
                entries[id] = Entry(observedAt: observation.observedAt, windows: observation.windows)
            }
        }
        entries = entries.filter { existing.contains($0.key) && now.timeIntervalSince($0.value.observedAt) < Self.maxAge }
    }

    /// `results` with the remembered reading filled in where a result has none (e.g. right after launch, when
    /// the CLI's sign-in has expired and nothing could be read yet). A result's own reading always wins.
    public func filling(_ results: [UUID: QuotaResult], now: Date) -> [UUID: QuotaResult] {
        var out = results
        for (id, result) in results where result.observation == nil {
            guard let entry = entries[id], now.timeIntervalSince(entry.observedAt) < Self.maxAge else { continue }
            out[id] = QuotaResult(observation: QuotaObservation(observedAt: entry.observedAt, windows: entry.windows),
                                  issue: result.issue)
        }
        return out
    }

    // MARK: Persistence

    public static func load(from url: URL) -> QuotaCache {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder.quotaCache.decode(QuotaCache.self, from: data) else { return QuotaCache() }
        return cache
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.quotaCache.encode(self).write(to: url, options: .atomic)
    }

    public static var defaultURL: URL {
        ConfigStore.defaultURL.deletingLastPathComponent().appendingPathComponent("quota-cache.json")
    }
}

private extension JSONEncoder {
    static var quotaCache: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

private extension JSONDecoder {
    static var quotaCache: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}
