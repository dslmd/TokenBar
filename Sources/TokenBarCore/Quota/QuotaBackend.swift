import Foundation

public enum RefreshPolicy: Sendable, Equatable {
    /// TokenBar may exchange the refresh token itself (and must write the result back).
    case selfRefresh
    /// The CLI owns the refresh chain; TokenBar never spends the refresh token.
    case delegateToCLI
}

public enum QuotaError: Error, Equatable, Sendable {
    case unauthorized
    case http(Int)
    case badResponse
    case transport(String)
}

/// Why online quota is not available for an account right now. Never contains token values.
public enum QuotaIssue: Error, Equatable, Sendable {
    case disabled
    case unsupported
    case notSignedIn
    case loginExpired(cli: String)
    /// A refresh would rotate the refresh token but the CLI's store cannot be updated safely.
    case cannotWriteBack(cli: String)
    case accessDenied
    case network
    case server(Int)
    case other

    public var message: String {
        switch self {
        case .disabled: return "Online quota is off."
        case .unsupported: return "Online quota is not available for this provider."
        case .notSignedIn: return "No sign-in found."
        case .loginExpired(let cli): return "Sign-in expired. Run \(cli) once to renew it."
        case .cannotWriteBack(let cli): return "Quota updates after \(cli) renews its sign-in. Run \(cli) once to update it now."
        case .accessDenied: return "No permission to read the sign-in."
        case .network: return "Network unavailable, will retry."
        case .server(let code): return "Quota service error (\(code))."
        case .other: return "Couldn't load online quota."
        }
    }
}

public extension QuotaIssue {
    /// The CLI's saved sign-in has expired and only the CLI itself may renew it (TokenBar never writes
    /// another app's Keychain item). Routine, not a problem: it resolves the next time the CLI runs.
    var isAwaitingCLIRenewal: Bool {
        if case .cannotWriteBack = self { return true }
        return false
    }
}

public struct QuotaResult: Equatable, Sendable {
    /// Last successfully fetched quota (kept while a later refresh fails).
    public var observation: QuotaObservation?
    public var issue: QuotaIssue?
    public init(observation: QuotaObservation? = nil, issue: QuotaIssue? = nil) {
        self.observation = observation
        self.issue = issue
    }
}

/// One provider's online-quota protocol: where credentials live, how they renew and how
/// the quota endpoint is called. Credentials are always the ones the CLI itself stored.
public protocol QuotaBackend: Sendable {
    var providerID: String { get }
    /// Command the user runs to log in again, for messages.
    var cliName: String { get }
    var refreshPolicy: RefreshPolicy { get }

    func credentialSources(forDataPath dataPath: String, home: URL) -> [CredentialSource]
    func parseCredentials(_ raw: Data) -> OAuthCredentials?
    /// nil when renewal is impossible (for example the OAuth client is not known).
    func refreshRequest(for credentials: OAuthCredentials) -> HTTPRequest?
    /// Returns the credential JSON with the refresh response merged in, keeping unknown fields.
    func applyRefresh(response: Data, to raw: Data, now: Date) -> Data?
    func fetchQuota(credentials: OAuthCredentials, http: HTTPClient, now: Date) async throws -> [QuotaWindow]
}

extension QuotaBackend {
    func get(_ http: HTTPClient, _ req: HTTPRequest) async throws -> Data {
        let res: HTTPResponse
        do { res = try await http.send(req) } catch { throw QuotaError.transport(String(describing: type(of: error))) }
        switch res.status {
        case 200..<300: return res.body
        case 401: throw QuotaError.unauthorized
        default: throw QuotaError.http(res.status)
        }
    }
}
