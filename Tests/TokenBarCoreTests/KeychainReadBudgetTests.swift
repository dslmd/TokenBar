import XCTest
@testable import TokenBarCore

extension QuotaTests {
    // Default Claude profile on macOS: login lives in another app's Keychain item (read-only for TokenBar), token expired.
    func testReviewBackgroundReadsWhileBlocked() async {
        let q = self
        let store = MemoryStore(q.claudeCreds(access: "AT-old", refresh: "RT-old", expires: q.t0.addingTimeInterval(-10)))
        store.writable = false
        let reads = Counter()
        store.onRead = { (_: MemoryStore) in _ = reads.bump() }
        let clock = Clock()
        let svc = q.makeService(backend: ClaudeQuotaBackend(), store: store, http: q.claudeHTTP(), clock: clock)
        var total = 0
        // One hour of the app's default 60 s refresh timer.
        for _ in 0..<60 {
            let r = await svc.refresh(accounts: [q.account], enabled: true)[q.account.id]!
            XCTAssertEqual(r.issue, .cannotWriteBack(cli: "claude"))
            clock.advance(60)
        }
        total = reads.bump() - 1
        print("REVIEW keychain reads in one hour:", total)
    }

    func testReviewDeniedRepromptsInBackground() async {
        let q = self
        let denied = DeniedStore()
        let clock = Clock()
        let svc = QuotaService(backends: [ClaudeQuotaBackend()], http: q.claudeHTTP(), home: URL(fileURLWithPath: "/nonexistent"),
                               keychain: { _ in denied }, now: { clock.now })
        for _ in 0..<(3 * 60) {
            _ = await svc.refresh(accounts: [q.account], enabled: true)
            clock.advance(60)
        }
        print("REVIEW denied prompts in three hours without user action:", denied.reads.bump() - 1)
    }
}

final class DeniedStore: CredentialBlobStore, @unchecked Sendable {
    let reads = Counter()
    let label = "denied"
    func read() throws -> Data { _ = reads.bump(); throw CredentialStoreError.denied }
    func write(_ data: Data) throws { throw CredentialStoreError.notWritable }
    func checkWritable() throws { throw CredentialStoreError.notWritable }
}
