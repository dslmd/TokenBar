import Foundation

/// Incremental scanner for one account. Not thread-safe; owned by `UsageCoordinator`.
///
/// Per file it remembers the byte offset consumed so far, the size/mtime seen and
/// the parser instance, so a refresh only reads newly appended bytes. Files whose
/// mtime is older than the retention window are ignored entirely.
final class AccountScanner {
    private struct FileState {
        var offset: UInt64 = 0
        var size: UInt64 = 0
        var mtime: Date = .distantPast
        var mode: FileReadMode
        var parser: FileParser
        var events: [String: UsageEvent] = [:]
        var quota: QuotaObservation?
    }

    /// Longest single line we are willing to buffer (Claude tool results can be large).
    static let maxLineBytes = 64 * 1024 * 1024
    private static let chunkSize = 1 << 20

    let account: Account
    let provider: any UsageProvider
    private var files: [String: FileState] = [:]
    private let fileManager = FileManager.default

    init(account: Account, provider: any UsageProvider) {
        self.account = account
        self.provider = provider
    }

    func refresh(now: Date, calendar: Calendar) -> AccountUsage {
        let periods = Periods(now: now, calendar: calendar)
        let roots = provider.scanRoots(forDataPath: expandPath(account.dataPath))
        let existingRoots = roots.filter { isDirectory($0) }
        if existingRoots.isEmpty {
            files.removeAll()
            // A profile that exists but was never used (e.g. just signed in from TokenBar) has no log folder
            // yet: that is "no usage", not a missing account folder.
            if isDirectory(URL(fileURLWithPath: expandPath(account.dataPath))) {
                return aggregate(now: now, periods: periods)
            }
            return AccountUsage(updatedAt: now, status: .dataDirectoryMissing)
        }

        var seen = Set<String>()
        for root in existingRoots {
            for item in enumerateFiles(under: root, modifiedSince: periods.retentionStart) {
                guard let mode = provider.readMode(forFile: item.url) else { continue }
                seen.insert(item.url.path)
                ingest(item, mode: mode, retentionStart: periods.retentionStart)
            }
        }
        // Forget files that disappeared or fell out of the retention window.
        for path in files.keys where !seen.contains(path) { files.removeValue(forKey: path) }

        return aggregate(now: now, periods: periods)
    }

    // MARK: - File discovery

    private struct FileItem {
        var url: URL
        var size: UInt64
        var mtime: Date
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func enumerateFiles(under root: URL, modifiedSince: Date) -> [FileItem] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let en = fileManager.enumerator(at: root.resolvingSymlinksInPath(),
                                              includingPropertiesForKeys: keys,
                                              options: [],
                                              errorHandler: { _, _ in true }) else { return [] }
        var out: [FileItem] = []
        for case let url as URL in en {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let mtime = values.contentModificationDate,
                  mtime >= modifiedSince else { continue }
            out.append(FileItem(url: url, size: UInt64(max(0, values.fileSize ?? 0)), mtime: mtime))
        }
        return out
    }

    // MARK: - Ingestion

    private func ingest(_ item: FileItem, mode: FileReadMode, retentionStart: Date) {
        let path = item.url.path
        var state = files[path] ?? FileState(mode: mode, parser: provider.makeParser(forFile: item.url))

        switch mode {
        case .wholeFile:
            if state.size == item.size && state.mtime == item.mtime && files[path] != nil { return }
            state = FileState(mode: mode, parser: provider.makeParser(forFile: item.url))
            if let data = try? Data(contentsOf: item.url, options: .mappedIfSafe) {
                apply(state.parser.consume(document: data), to: &state, retentionStart: retentionStart)
            }
            state.size = item.size
            state.mtime = item.mtime
            files[path] = state

        case .lines:
            if item.size < state.offset {
                // Truncated or replaced: start over.
                state = FileState(mode: mode, parser: provider.makeParser(forFile: item.url))
            }
            state.mtime = item.mtime
            state.size = item.size
            if item.size > state.offset {
                readLines(url: item.url, state: &state, retentionStart: retentionStart)
            }
            files[path] = state
        }
    }

    private func apply(_ out: ParseOutput, to state: inout FileState, retentionStart: Date) {
        for e in out.events where e.timestamp >= retentionStart {
            if let old = state.events[e.key] {
                var merged = e
                merged.tokens = old.tokens.componentMax(e.tokens)
                state.events[e.key] = merged
            } else {
                state.events[e.key] = e
            }
        }
        if let q = out.quota, q.observedAt >= (state.quota?.observedAt ?? .distantPast) {
            state.quota = q
        }
    }

    /// Reads complete lines from `state.offset` to EOF. A trailing partial line (a
    /// writer mid-append) is left unconsumed unless it already is a full JSON object.
    private func readLines(url: URL, state: inout FileState, retentionStart: Date) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: state.offset) } catch { return }

        var pending = Data()
        var pendingStart = state.offset      // file offset of pending[0]
        var discarding = false               // inside an over-long line
        var consumedUpTo = state.offset

        func emit(_ line: Data, at offset: UInt64) {
            var l = line
            if l.last == 0x0D { l.removeLast() }
            guard !l.isEmpty else { return }
            apply(state.parser.consume(line: l, offset: offset), to: &state, retentionStart: retentionStart)
        }

        while true {
            let chunk: Data
            do { chunk = try handle.read(upToCount: Self.chunkSize) ?? Data() } catch { break }
            if chunk.isEmpty { break }
            pending.append(chunk)

            var lineStart = pending.startIndex
            while let nl = pending[lineStart...].firstIndex(of: 0x0A) {
                let offset = pendingStart + UInt64(lineStart - pending.startIndex)
                if discarding {
                    discarding = false
                } else {
                    emit(pending[lineStart..<nl], at: offset)
                }
                lineStart = pending.index(after: nl)
                consumedUpTo = pendingStart + UInt64(lineStart - pending.startIndex)
            }
            if lineStart > pending.startIndex {
                pendingStart += UInt64(lineStart - pending.startIndex)
                pending = Data(pending[lineStart...])
            }
            if pending.count > Self.maxLineBytes {
                // Pathological line: skip it, but keep the offset moving.
                pendingStart += UInt64(pending.count)
                consumedUpTo = pendingStart
                pending = Data()
                discarding = true
            }
        }

        // Tail without newline: only trust it when it is already a complete JSON object.
        if !pending.isEmpty, !discarding, JSON.object(pending) != nil {
            emit(pending, at: pendingStart)
            consumedUpTo = pendingStart + UInt64(pending.count)
        }
        state.offset = consumedUpTo
    }

    // MARK: - Aggregation

    private func aggregate(now: Date, periods: Periods) -> AccountUsage {
        // Merge across files: the same call can appear in several logs (resumed sessions).
        var merged: [String: UsageEvent] = [:]
        var quota: QuotaObservation?
        for (_, state) in files {
            for (key, e) in state.events {
                if var old = merged[key] {
                    old.tokens = old.tokens.componentMax(e.tokens)
                    merged[key] = old
                } else {
                    merged[key] = e
                }
            }
            if let q = state.quota, q.observedAt >= (quota?.observedAt ?? .distantPast) { quota = q }
        }

        var today = TokenBreakdown.zero, week = TokenBreakdown.zero, month = TokenBreakdown.zero
        var daily = periods.dayStarts.map { DailyUsage(day: $0) }
        var last: Date?
        for e in merged.values {
            if e.timestamp >= periods.weekStart, let i = periods.dayStarts.lastIndex(where: { $0 <= e.timestamp }) {
                daily[i].tokens += e.tokens
            }
            if e.timestamp >= periods.monthStart { month += e.tokens }
            if e.timestamp >= periods.weekStart { week += e.tokens }
            if e.timestamp >= periods.todayStart { today += e.tokens }
            if last == nil || e.timestamp > last! { last = e.timestamp }
        }
        return AccountUsage(today: today, last7Days: week, month: month, daily: daily, quota: quota,
                            lastActivity: last, updatedAt: now, filesTracked: files.count,
                            status: merged.isEmpty ? .noRecentData : .ok)
    }
}

/// Calendar boundaries for the reported periods.
struct Periods {
    let todayStart: Date
    let weekStart: Date      // start of day, 6 days before today => 7 calendar days incl. today
    let monthStart: Date
    /// Start of each of the last seven days, oldest first.
    let dayStarts: [Date]
    /// Anything older than this can never be shown, so it is not parsed or kept.
    let retentionStart: Date

    init(now: Date, calendar: Calendar) {
        let today = calendar.startOfDay(for: now)
        let week = calendar.date(byAdding: .day, value: -6, to: today) ?? today.addingTimeInterval(-6 * 86400)
        let month = calendar.dateInterval(of: .month, for: now)?.start ?? today
        todayStart = today
        weekStart = week
        monthStart = month
        dayStarts = (0..<7).map { calendar.date(byAdding: .day, value: $0, to: week) ?? week.addingTimeInterval(Double($0) * 86400) }
        // One extra day of slack so files touched just before the boundary are still read.
        retentionStart = min(week, month).addingTimeInterval(-86400)
    }
}
