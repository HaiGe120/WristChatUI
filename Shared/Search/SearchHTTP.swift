import Foundation

enum SearchDeadline {
    static func run<T: Sendable>(seconds: Double = 90, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw CancellationError() }
            return value
        }
    }
}

/// Redirects are deliberately rejected, including same-origin redirects: a configured search
/// destination cannot move credentials or a private query to an unreviewed URL.
final class SearchHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let customConfiguration: URLSessionConfiguration?
    init(configuration: URLSessionConfiguration? = nil) { self.customConfiguration = configuration; super.init() }
    private(set) lazy var session: URLSession = {
        let configuration = customConfiguration ?? URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func close() { session.invalidateAndCancel() }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    static func request(source: SearchSourceProfile, credential: String?) throws -> URLRequest {
        var request = URLRequest(url: try source.validatedURL())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if source.authentication != .none || source.kind == .miniMaxPlan {
            guard let credential, !credential.isEmpty, credential.count <= 16_384,
                  !credential.contains("\r"), !credential.contains("\n") else { throw SearchError.missingCredential }
            if source.authentication == .bearer || source.kind == .miniMaxPlan {
                request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
            } else {
                request.setValue(credential, forHTTPHeaderField: source.headerName)
            }
        }
        return request
    }

    static func collect(_ bytes: URLSession.AsyncBytes, limit: Int = 524_288) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw SearchError.tooLarge }
            data.append(byte)
        }
        return data
    }

    static func validateStatus(_ response: HTTPURLResponse) throws {
        if response.statusCode == 401 {
            if response.value(forHTTPHeaderField: "WWW-Authenticate")?.lowercased().contains("resource_metadata") == true {
                throw SearchError.oauthRequired
            }
            throw SearchError.authenticationRequired
        }
        if response.statusCode == 403 { throw SearchError.authenticationRequired }
        guard (200..<300).contains(response.statusCode) else { throw SearchError.http(response.statusCode) }
    }
}
