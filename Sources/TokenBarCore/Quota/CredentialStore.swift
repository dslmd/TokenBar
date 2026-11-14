import Foundation

/// OAuth material parsed from a CLI's credential file. Values are never logged or displayed.
public struct OAuthCredentials: Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var accountID: String?

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, accountID: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.accountID = accountID
    }

    /// Unknown expiry counts as not expired (a 401 will still trigger the renewal path).
    public func isExpired(at now: Date, skew: TimeInterval = 60) -> Bool {
        guard let e = expiresAt else { return false }
        return e.timeIntervalSince(now) <= skew
    }

    // Keep secrets out of accidental `print`/string interpolation.
    public var debugDescription: String { "OAuthCredentials(<redacted>)" }
}

public enum CredentialStoreError: Error, Equatable, Sendable {
    case notFound
    case unreadable
    /// The user (or OS) refused access, e.g. a denied Keychain prompt.
    case denied
    case notWritable
}

/// Raw bytes of one credential store (a JSON file or a Keychain item). The quota code
/// edits the JSON itself so fields it does not know about survive a write-back.
public protocol CredentialBlobStore: Sendable {
    /// Stable, non-secret name used for diagnostics and as part of backoff keys.
    var label: String { get }
    func read() throws -> Data
    func write(_ data: Data) throws
    /// Proves a later `write` can succeed *before* a rotating refresh token is spent.
    func checkWritable() throws
}

/// Where a CLI keeps its credentials.
public enum CredentialSource: Sendable, Equatable {
    case file(URL)
    case keychain(service: String)
}

/// JSON file store with atomic, permission-preserving writes (temp file + rename).
public struct FileBlobStore: CredentialBlobStore {
    public let url: URL
    public var label: String { url.path }

    public init(url: URL) { self.url = url }

    public func read() throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else { throw CredentialStoreError.notFound }
        guard let d = try? Data(contentsOf: url) else { throw CredentialStoreError.unreadable }
        return d
    }

    public func checkWritable() throws {
        let fm = FileManager.default
        let real = url.resolvingSymlinksInPath()
        guard fm.isWritableFile(atPath: real.path),
              fm.isWritableFile(atPath: real.deletingLastPathComponent().path) else {
            throw CredentialStoreError.notWritable
        }
    }

    public func write(_ data: Data) throws {
        let fm = FileManager.default
        let real = url.resolvingSymlinksInPath()      // do not replace a symlink with a regular file
        let dir = real.deletingLastPathComponent()
        let existing = (try? fm.attributesOfItem(atPath: real.path)[.posixPermissions]) as? NSNumber
        let perms = existing?.intValue ?? 0o600
        let tmp = dir.appendingPathComponent(".\(real.lastPathComponent).tokenbar-\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CredentialStoreError.notWritable
        }
        do {
            let h = try FileHandle(forWritingTo: tmp)
            try h.write(contentsOf: data)
            try h.synchronize()
            try h.close()
            try fm.setAttributes([.posixPermissions: perms], ofItemAtPath: tmp.path)
            if rename(tmp.path, real.path) != 0 { throw CredentialStoreError.notWritable }
        } catch {
            try? fm.removeItem(at: tmp)
            throw CredentialStoreError.notWritable
        }
    }
}

// MARK: - JSON helpers shared by the backends

enum CredentialJSON {
    static func parse(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func serialize(_ obj: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Epoch milliseconds, tolerating seconds and numeric strings.
    static func date(fromEpoch value: Any?) -> Date? {
        guard let n = JSON.double(value) ?? (value as? String).flatMap(Double.init), n > 0 else { return nil }
        return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n)
    }

    /// `exp` claim of a JWT, without verifying it.
    static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64), let obj = parse(data),
              let exp = JSON.double(obj["exp"]), exp > 1_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}
