import XCTest
@testable import TokenBarCore

/// Wraps a provider's parser to count how many lines are actually parsed.
final class LineCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}

struct CountingClaude: UsageProvider {
    let counter: LineCounter
    let inner = ClaudeProvider()
    var id: String { inner.id }
    var displayName: String { inner.displayName }
    var symbolName: String { inner.symbolName }
    var dataPathHint: String { inner.dataPathHint }
    func defaultDataPaths(environment: [String: String], home: URL) -> [String] { [] }
    func scanRoots(forDataPath dataPath: String) -> [URL] { inner.scanRoots(forDataPath: dataPath) }
    func readMode(forFile url: URL) -> FileReadMode? { inner.readMode(forFile: url) }
    func makeParser(forFile url: URL) -> FileParser { Wrapper(inner: inner.makeParser(forFile: url), counter: counter) }

    final class Wrapper: FileParser {
        let inner: FileParser; let counter: LineCounter
        init(inner: FileParser, counter: LineCounter) { self.inner = inner; self.counter = counter }
        func consume(line: Data, offset: UInt64) -> ParseOutput { counter.bump(); return inner.consume(line: line, offset: offset) }
    }
}

final class IncrementalTests: XCTestCase {
    private func claudeLine(id: String, out: Int, ts: String = "2025-10-15T10:00:00.000Z") -> String {
        "{\"sessionId\":\"s\",\"message\":{\"id\":\"\(id)\",\"model\":\"claude-sonnet-4-5\",\"usage\":{\"input_tokens\":1,\"output_tokens\":\(out),\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}},\"requestId\":\"r\(id)\",\"type\":\"assistant\",\"timestamp\":\"\(ts)\"}"
    }

    func testOnlyAppendedBytesAreParsedOnRefresh() async throws {
        let dir = try TestSupport.copyFixture("claude")
        let counter = LineCounter()
        let coordinator = UsageCoordinator(registry: ProviderRegistry(providers: [CountingClaude(counter: counter)]))
        let account = Account(providerID: "claude", name: "t", dataPath: dir.path)

        let first = await coordinator.refresh(accounts: [account], now: TestSupport.now, calendar: TestSupport.utc)[account.id]!
        let afterFirst = counter.count
        XCTAssertGreaterThan(afterFirst, 0)

        let again = await coordinator.refresh(accounts: [account], now: TestSupport.now, calendar: TestSupport.utc)[account.id]!
        XCTAssertEqual(counter.count, afterFirst, "unchanged files must not be re-read")
        XCTAssertEqual(first.today, again.today)

        let file = dir.appendingPathComponent("projects/-Users-me-proj/sess-2.jsonl")
        try TestSupport.append(claudeLine(id: "msg_NEW", out: 1000) + "\n", to: file)
        let third = await coordinator.refresh(accounts: [account], now: TestSupport.now, calendar: TestSupport.utc)[account.id]!
        XCTAssertEqual(counter.count, afterFirst + 1, "only the appended line is parsed")
        XCTAssertEqual(third.today.output, first.today.output + 1000)
        XCTAssertEqual(third.today.input, first.today.input + 1)
    }

    func testPartialWriteIsPickedUpOnceComplete() async throws {
        let home = try TestSupport.tempDir()
        let proj = home.appendingPathComponent("projects/p")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let file = proj.appendingPathComponent("s.jsonl")
        let line = claudeLine(id: "m1", out: 77)
        let cut = line.index(line.startIndex, offsetBy: line.count / 2)
        try Data((claudeLine(id: "m0", out: 5) + "\n" + line[..<cut]).utf8).write(to: file)

        let c = UsageCoordinator()
        let a = await TestSupport.usage(provider: "claude", path: home, coordinator: c)
        XCTAssertEqual(a.today.output, 5, "half-written line is ignored")

        try TestSupport.append(String(line[cut...]) + "\n", to: file)
        let b = await TestSupport.usage(provider: "claude", path: home, coordinator: c)
        XCTAssertEqual(b.today.output, 5 + 77)
    }

    func testCompleteLineWithoutTrailingNewlineIsAccepted() async throws {
        let home = try TestSupport.tempDir()
        let proj = home.appendingPathComponent("projects/p")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let file = proj.appendingPathComponent("s.jsonl")
        try Data(claudeLine(id: "m1", out: 9).utf8).write(to: file)
        let c = UsageCoordinator()
        let a = await TestSupport.usage(provider: "claude", path: home, coordinator: c)
        XCTAssertEqual(a.today.output, 9)
        // The writer later adds the newline and a new record: no double counting.
        try TestSupport.append("\n" + claudeLine(id: "m2", out: 1) + "\n", to: file)
        let b = await TestSupport.usage(provider: "claude", path: home, coordinator: c)
        XCTAssertEqual(b.today.output, 10)
    }

    func testTruncatedFileIsReparsedAndDeletedFileForgotten() async throws {
        let home = try TestSupport.tempDir()
        let proj = home.appendingPathComponent("projects/p")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let file = proj.appendingPathComponent("s.jsonl")
        try Data((claudeLine(id: "a", out: 100) + "\n" + claudeLine(id: "b", out: 200) + "\n").utf8).write(to: file)
        let c = UsageCoordinator()
        let a = await TestSupport.usage(provider: "claude", path: home, coordinator: c)
        XCTAssertEqual(a.today.output, 300)

        try Data((claudeLine(id: "z", out: 7) + "\n").utf8).write(to: file)   // shorter than before
        let b = await TestSupport.usage(provider: "claude", path: home, coordinator: c)
        XCTAssertEqual(b.today.output, 7)

        try FileManager.default.removeItem(at: file)
        let d = await TestSupport.usage(provider: "claude", path: home, coordinator: c)
        XCTAssertEqual(d.today, .zero)
        XCTAssertEqual(d.filesTracked, 0)
    }

    func testCodexCumulativeStateSurvivesAcrossRefreshes() async throws {
        let home = try TestSupport.tempDir()
        let dir = home.appendingPathComponent("sessions/2025/10/15")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("rollout-x.jsonl")
        func tc(_ ts: String, _ i: Int, _ c: Int, _ o: Int, last: (Int, Int, Int)) -> String {
            "{\"timestamp\":\"\(ts)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\(i),\"cached_input_tokens\":\(c),\"output_tokens\":\(o),\"total_tokens\":\(i + o)},\"last_token_usage\":{\"input_tokens\":\(last.0),\"cached_input_tokens\":\(last.1),\"output_tokens\":\(last.2),\"total_tokens\":0}}}}\n"
        }
        try Data(tc("2025-10-15T09:00:00Z", 100, 0, 10, last: (100, 0, 10)).utf8).write(to: file)
        let c = UsageCoordinator()
        let a = await TestSupport.usage(provider: "codex", path: home, coordinator: c)
        XCTAssertEqual(a.today.input, 100)
        // `last` deliberately disagrees with the total difference: totals win after the first snapshot.
        try TestSupport.append(tc("2025-10-15T09:05:00Z", 400, 100, 50, last: (1, 1, 1)), to: file)
        let b = await TestSupport.usage(provider: "codex", path: home, coordinator: c)
        XCTAssertEqual(b.today, TokenBreakdown(input: 100 + 200, output: 10 + 40, cacheRead: 100, cacheWrite: 0))
    }
}
