import Foundation

/// How a provider's log file is consumed.
public enum FileReadMode: Sendable {
    /// Append-only JSON Lines: read incrementally from the last offset.
    case lines
    /// A single JSON document that is rewritten as a whole: re-parsed when it changes.
    case wholeFile
}

/// What a parser extracted from a chunk of a log.
public struct ParseOutput {
    public var events: [UsageEvent] = []
    public var quota: QuotaObservation?
    public init(events: [UsageEvent] = [], quota: QuotaObservation? = nil) {
        self.events = events
        self.quota = quota
    }
    public static let empty = ParseOutput()
}

/// Per-file parser. One instance is created per log file and kept alive between
/// refreshes, so it may carry state (e.g. Codex's running cumulative totals).
/// Implementations must never crash or throw on malformed input.
public protocol FileParser: AnyObject {
    /// Called with each complete line (no trailing newline). `offset` is the byte
    /// offset of the line start, useful for building stable event keys.
    func consume(line: Data, offset: UInt64) -> ParseOutput
    /// Called instead for `FileReadMode.wholeFile` files.
    func consume(document: Data) -> ParseOutput
}

public extension FileParser {
    func consume(document: Data) -> ParseOutput { .empty }
}

/// A source of token usage. Adding a provider means adding one file that
/// implements this protocol and listing it in `ProviderRegistry`.
public protocol UsageProvider: Sendable {
    /// Stable identifier persisted in the config file (never localised).
    var id: String { get }
    /// Name shown in the UI.
    var displayName: String { get }
    /// SF Symbol used by the app.
    var symbolName: String { get }
    /// Chinese help text describing what the account's data path should be.
    var dataPathHint: String { get }
    /// Whether this provider can use an API key stored in the Keychain.
    /// Every current provider reads local logs only, so this is false.
    var supportsAPIKey: Bool { get }

    /// Candidate data paths for auto-detection, most preferred first.
    func defaultDataPaths(environment: [String: String], home: URL) -> [String]
    /// Directories to scan for an account's data path.
    func scanRoots(forDataPath dataPath: String) -> [URL]
    /// Decide whether a file under a scan root is a log this provider understands.
    func readMode(forFile url: URL) -> FileReadMode?
    /// Create the stateful parser for a log file.
    func makeParser(forFile url: URL) -> FileParser
}

public extension UsageProvider {
    var supportsAPIKey: Bool { false }
}

/// Registry of known providers, in display order.
public struct ProviderRegistry: Sendable {
    public let providers: [any UsageProvider]

    public init(providers: [any UsageProvider]) { self.providers = providers }

    public static let `default` = ProviderRegistry(providers: [
        ClaudeProvider(), CodexProvider(), GeminiProvider(), MuseProvider(),
    ])

    public func provider(withID id: String) -> (any UsageProvider)? {
        providers.first { $0.id == id }
    }
}

/// Expands `~` and resolves relative bits of a user-entered path.
public func expandPath(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}
