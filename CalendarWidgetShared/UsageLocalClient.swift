import Foundation

/// The helper exposes sanitized quota records on this Mac only; no account credentials are sent.
enum UsageLocalClient {
    static func fetch() async throws -> UsageWidgetSnapshot {
        #if os(macOS) || targetEnvironment(macCatalyst)
        let endpoint = URL(string: "http://localhost:48763/v1/usage")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 5
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.connectionProxyDictionary = [:]
        let delegate = UsageLocalRequestDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200, http.url == endpoint else { throw UsageLocalClientError.invalidResponse }
        guard response.expectedContentLength <= Int64(UsageWidgetConstants.maximumFileSize) else { throw UsageWidgetError.oversizedFile }
        var data = Data()
        data.reserveCapacity(min(max(Int(response.expectedContentLength), 0), UsageWidgetConstants.maximumFileSize))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < UsageWidgetConstants.maximumFileSize else { throw UsageWidgetError.oversizedFile }
            data.append(byte)
        }
        try Task.checkCancellation()
        return try UsageWidgetSnapshot.decode(data)
        #else
        throw UsageLocalClientError.unsupportedPlatform
        #endif
    }
}

enum UsageLocalClientError: Error { case unsupportedPlatform, invalidResponse, unavailableRecord }

#if os(macOS) || targetEnvironment(macCatalyst)
private final class UsageLocalRequestDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}
#endif
