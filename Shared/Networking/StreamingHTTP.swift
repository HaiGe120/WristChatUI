import Foundation

/// Credentials remain at the configured origin. In particular, OAuth requests never follow redirects.
private final class CredentialRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let allowsSameOrigin: Bool
    init(allowsSameOrigin: Bool) { self.allowsSameOrigin = allowsSameOrigin }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard allowsSameOrigin, let old = task.originalRequest?.url, let next = request.url,
              old.scheme?.lowercased() == next.scheme?.lowercased(),
              old.host?.lowercased() == next.host?.lowercased(), old.port == next.port else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}

public enum StreamingHTTP {
    public static func session(allowsSameOriginRedirects: Bool = true) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        // The engine owns useful-progress deadlines (45s chat / 75s search).
        // Keep the transport ceiling above both so it cannot prematurely end a search.
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 240
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": "WristAssistant/1.0 (iOS+watchOS)"]
        return URLSession(configuration: config, delegate: CredentialRedirectGuard(allowsSameOrigin: allowsSameOriginRedirects), delegateQueue: nil)
    }

    public static func send(_ request: URLRequest, session: URLSession) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.transport("Non-HTTP response") }
            guard (200..<300).contains(http.statusCode) else {
                var errorBody = ""
                for try await line in bytes.lines {
                    errorBody += line.prefix(max(0, 4096 - errorBody.count))
                    if errorBody.count >= 4096 { break }
                }
                throw APIError.response(status: http.statusCode, body: errorBody)
            }
            return (bytes, http)
        } catch { throw APIError.from(error) }
    }
}
