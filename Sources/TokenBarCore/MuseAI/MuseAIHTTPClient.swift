import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `HTTPClient` for muse.ai. Use this one, not `URLSessionHTTPClient`, for `MuseAIFetcher`:
///
/// - Like CodexBar's production transport, it follows only same-origin HTTPS redirects and refuses
///   cross-origin ones (CodexBar docs/plugins.md, "cross-origin redirects are rejected"). This keeps
///   the explicitly set `Cookie` header from being forwarded to another host, and it lets the fetcher
///   see a redirect to `auth.muse.ai`, which is how muse.ai signals a signed-out session.
/// - `HTTPResponse` has no header field, so for a 3xx response that was not followed the body is
///   replaced by the UTF-8 `Location` value (empty when absent). `MuseAIFetcher` relies on this.
/// - No cookie storage, credential storage or cache.
public final class MuseAIHTTPClient: HTTPClient, @unchecked Sendable {
    private let session: URLSession
    /// Responses larger than this are truncated to an empty body (chunks are capped separately).
    private let maxBodyBytes: Int

    public init(maxBodyBytes: Int = 16 << 20) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 60
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        self.maxBodyBytes = maxBodyBytes
        session = URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var r = URLRequest(url: request.url)
        r.httpMethod = request.method
        r.timeoutInterval = request.timeout
        r.httpBody = request.body
        r.httpShouldHandleCookies = false
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        let limit = maxBodyBytes
        return try await withCheckedThrowingContinuation { cont in
            session.dataTask(with: r) { data, response, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let http = response as? HTTPURLResponse {
                    if (300..<400).contains(http.statusCode) {
                        let location = Self.header("Location", in: http) ?? ""
                        cont.resume(returning: HTTPResponse(status: http.statusCode, body: Data(location.utf8)))
                    } else {
                        let body = data ?? Data()
                        cont.resume(returning: HTTPResponse(status: http.statusCode, body: body.count > limit ? Data() : body))
                    }
                } else {
                    cont.resume(throwing: URLError(.badServerResponse))
                }
            }.resume()
        }
    }

    private static func header(_ name: String, in response: HTTPURLResponse) -> String? {
        for (k, v) in response.allHeaderFields {
            if let key = k as? String, key.caseInsensitiveCompare(name) == .orderedSame { return v as? String }
        }
        return nil
    }

    /// Allows same-origin HTTPS redirects only; otherwise the 3xx response itself is returned.
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard let from = task.originalRequest?.url, let to = request.url,
                  from.scheme?.lowercased() == "https", to.scheme?.lowercased() == "https",
                  from.host?.lowercased() == to.host?.lowercased(), (from.port ?? 443) == (to.port ?? 443) else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }
}
