import Foundation
import XCTest
@testable import TokenBarCore

enum TestSupport {
    /// 2025-10-15T12:00:00Z, the "current time" every fixture is written against.
    static let now = Date(timeIntervalSince1970: 1_760_529_600)

    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    static var fixtures: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
    }

    /// Copies a fixture subtree into a fresh temp dir so tests can mutate it.
    static func copyFixture(_ name: String) throws -> URL {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent(name),
                                         to: dest.appendingPathComponent(name))
        return dest.appendingPathComponent(name)
    }

    static func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func usage(provider: String, path: URL, coordinator: UsageCoordinator = UsageCoordinator(),
                      now: Date = TestSupport.now) async -> AccountUsage {
        let account = Account(providerID: provider, name: "t", dataPath: path.path)
        return await coordinator.refresh(accounts: [account], now: now, calendar: utc)[account.id]!
    }

    static func append(_ text: String, to url: URL) throws {
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: Data(text.utf8))
    }
}
