import XCTest
@testable import TokenBarCore

final class ProviderTests: XCTestCase {
    func testClaudeDedupesStreamingAndResumedSessions() async throws {
        let dir = try TestSupport.copyFixture("claude")
        let u = await TestSupport.usage(provider: "claude", path: dir)
        XCTAssertEqual(u.status, .ok)
        // A (final streamed line wins), B (duplicated in sess-2), E, F (subagent file).
        XCTAssertEqual(u.today, TokenBreakdown(input: 17, output: 398, cacheRead: 5000, cacheWrite: 1000))
        XCTAssertEqual(u.last7Days, TokenBreakdown(input: 27, output: 418, cacheRead: 5500, cacheWrite: 1000))
        XCTAssertEqual(u.month, TokenBreakdown(input: 28, output: 419, cacheRead: 5500, cacheWrite: 1000))
        XCTAssertNil(u.quota)
        XCTAssertEqual(u.filesTracked, 3)
        XCTAssertEqual(u.lastActivity, ISO8601.parse("2025-10-15T09:10:00.000Z"))
    }

    func testCodexCumulativeTotalsAndRateLimits() async throws {
        let dir = try TestSupport.copyFixture("codex")
        let r = await TestSupport.usage(provider: "codex", path: dir)
        XCTAssertEqual(r.status, .ok)
        // Today: delta1 = first snapshot's last (800/200/100), duplicate skipped,
        // delta2 = total difference (2000 in, 1000 cached, 300 out).
        XCTAssertEqual(r.today, TokenBreakdown(input: 800 + 1000, output: 100 + 300, cacheRead: 200 + 1000, cacheWrite: 0))
        // Oct 11 file: fork-style first snapshot uses `last`, then a delta, then a counter reset.
        XCTAssertEqual(r.last7Days, TokenBreakdown(input: 1800 + 200 + 400 + 100, output: 400 + 50 + 20 + 10,
                                                  cacheRead: 1200 + 600 + 100 + 0, cacheWrite: 0))
        XCTAssertEqual(r.month, r.last7Days)

        let q = try XCTUnwrap(r.quota)
        XCTAssertEqual(q.observedAt, ISO8601.parse("2025-10-15T09:05:00Z"))
        XCTAssertEqual(q.windows.count, 2)
        XCTAssertEqual(q.windows[0].label, "5-hour")
        XCTAssertEqual(q.windows[0].usedPercent, 15.0)
        XCTAssertEqual(q.windows[0].windowMinutes, 300)
        XCTAssertEqual(q.windows[0].resetsAt, Date(timeIntervalSince1970: 1_760_540_000))
        XCTAssertEqual(q.windows[1].label, "Weekly")
        XCTAssertEqual(q.windows[1].usedPercent, 41.0)
        XCTAssertFalse(q.windows[0].isStale(at: TestSupport.now))
        XCTAssertTrue(q.windows[0].isStale(at: Date(timeIntervalSince1970: 1_760_540_001)))
    }

    func testCodexResetsInSecondsFallback() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        let w = CodexParser.quotaWindows(from: ["primary": ["used_percent": 5.0, "window_minutes": 300, "resets_in_seconds": 3600]], observedAt: t)
        XCTAssertEqual(w.first?.resetsAt, t.addingTimeInterval(3600))
    }

    func testGeminiJSONLAndLegacyJSON() async throws {
        let dir = try TestSupport.copyFixture("gemini")
        let u = await TestSupport.usage(provider: "gemini", path: dir)
        XCTAssertEqual(u.status, .ok)
        // g1 (deduped): input 1000-400, output 50+30 thoughts, cache 400
        // g2: input 2000 + 20 tool, output 100; sub-agent g3: 100/10.
        XCTAssertEqual(u.today, TokenBreakdown(input: 600 + 2020 + 100, output: 80 + 100 + 10, cacheRead: 400, cacheWrite: 0))
        // Legacy whole-file session adds 400/50/100 on Oct 11; checkpoint-*.json ignored.
        XCTAssertEqual(u.last7Days, TokenBreakdown(input: 2720 + 400, output: 190 + 50, cacheRead: 500, cacheWrite: 0))
        XCTAssertNil(u.quota)
        XCTAssertEqual(u.filesTracked, 3)
    }

    func testMuseCodeEventsRetainedFramesAndSubagents() async throws {
        let dir = try TestSupport.copyFixture("muse")
        let u = await TestSupport.usage(provider: "muse", path: dir)
        XCTAssertEqual(u.status, .ok)
        // seq1 (replayed twice): 26964-5105 in, 379 out, 5105 cache. seq3: 1000/100.
        // seq4 (inside retained_frame): 400 in, 50 out, 100 cache. child: 200/20.
        // workflow_child_lifecycle and the truncated line are ignored.
        XCTAssertEqual(u.today, TokenBreakdown(input: 21859 + 1000 + 400 + 200, output: 379 + 100 + 50 + 20, cacheRead: 5105 + 100, cacheWrite: 0))
        XCTAssertEqual(u.last7Days.input, u.today.input + 100)
        XCTAssertEqual(u.last7Days.output, u.today.output + 10)
        XCTAssertEqual(u.filesTracked, 3)
    }

    func testMissingDirectoryAndEmptyDirectory() async throws {
        let missing = try TestSupport.tempDir().appendingPathComponent("nope")
        let m = await TestSupport.usage(provider: "claude", path: missing)
        XCTAssertEqual(m.status, .dataDirectoryMissing)
        XCTAssertEqual(m.today, .zero)

        // A fresh profile folder without any log folder yet (just signed in): no usage, not "missing".
        let fresh = try TestSupport.tempDir()
        let f = await TestSupport.usage(provider: "claude", path: fresh)
        XCTAssertEqual(f.status, .noRecentData)
        XCTAssertEqual(f.today, .zero)

        let empty = try TestSupport.tempDir()
        try FileManager.default.createDirectory(at: empty.appendingPathComponent("projects"), withIntermediateDirectories: true)
        let e = await TestSupport.usage(provider: "claude", path: empty)
        XCTAssertEqual(e.status, .noRecentData)
    }

    func testUnknownProviderDoesNotCrash() async throws {
        let account = Account(providerID: "nope", name: "x", dataPath: "/tmp")
        let r = await UsageCoordinator().refresh(accounts: [account])
        XCTAssertEqual(r[account.id]?.status, .unknownProvider)
    }

    func testGarbageFilesDoNotCrash() async throws {
        let home = try TestSupport.tempDir()
        let proj = home.appendingPathComponent("projects/p")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        var junk = Data((0..<4096).map { _ in UInt8.random(in: 0...255) })
        junk.append(contentsOf: Array("\n{\"message\":{\"usage\":5}}\n[1,2,3]\n\"usage\"\n{\"usage\":{}}\n".utf8))
        try junk.write(to: proj.appendingPathComponent("junk.jsonl"))
        try Data().write(to: proj.appendingPathComponent("empty.jsonl"))
        let u = await TestSupport.usage(provider: "claude", path: home)
        XCTAssertEqual(u.today, .zero)
        XCTAssertEqual(u.status, .noRecentData)
    }
}
