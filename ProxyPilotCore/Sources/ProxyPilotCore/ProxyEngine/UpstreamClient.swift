import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Forwards requests to the upstream LLM provider.
enum UpstreamClient {

    // MARK: - Buffered

    /// Forward a buffered request and return the full response.
    static func forward(
        path: String,
        method: String,
        headers: [(String, String)],
        body: Data?,
        config: ProxyConfiguration
    ) async throws -> (Data, Int, [(String, String)]) {
        let request = buildRequest(
            path: path,
            method: method,
            headers: headers,
            body: body,
            config: config
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpstreamError.invalidResponse
        }

        let responseHeaders: [(String, String)] = httpResponse.allHeaderFields.compactMap { key, value in
            guard let name = key as? String, let val = value as? String else { return nil }
            return (name, val)
        }

        return (data, httpResponse.statusCode, responseHeaders)
    }

    // MARK: - Streaming

    /// Forward a streaming request, yielding data chunks as they arrive.
    static func forwardStreaming(
        path: String,
        method: String,
        headers: [(String, String)],
        body: Data?,
        config: ProxyConfiguration
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let request = buildRequest(
                path: path,
                method: method,
                headers: headers,
                body: body,
                config: config
            )

            Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: UpstreamError.invalidResponse)
                        return
                    }

                    // If upstream returns an error status, read the full body and throw
                    if httpResponse.statusCode >= 400 {
                        var errorData = Data()
                        for try await byte in bytes {
                            errorData.append(byte)
                        }
                        continuation.finish(throwing: UpstreamError.httpError(
                            statusCode: httpResponse.statusCode,
                            body: errorData
                        ))
                        return
                    }

                    // Yield lines as they arrive (SSE is newline-delimited)
                    for try await line in bytes.lines {
                        let lineData = Data((line + "\n").utf8)
                        continuation.yield(lineData)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Private Helpers

    /// URLSession with a reasonable connection timeout for upstream requests.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        // Short connection timeout so tests against unreachable hosts fail fast
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private static func buildRequest(
        path: String,
        method: String,
        headers: [(String, String)],
        body: Data?,
        config: ProxyConfiguration
    ) -> URLRequest {
        let upstreamURL = buildUpstreamURL(
            path: path,
            config: config
        )

        var request = URLRequest(url: upstreamURL)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30

        // Forward relevant headers, excluding auth headers (we set our own)
        // and any client API key headers that could leak to the upstream provider.
        let skipHeaders: Set<String> = ["authorization", "host", "content-length", "x-api-key", "api-key"]
        for (name, value) in headers {
            if skipHeaders.contains(name.lowercased()) { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }

        // Set upstream auth
        if let apiKey = config.upstreamAPIKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        return request
    }

    static func buildUpstreamURL(
        path: String,
        config: ProxyConfiguration
    ) -> URL {
        var base = config.upstreamAPIBaseURL
        while base.hasSuffix("/") {
            base.removeLast()
        }
        var effectivePath = path
        if !effectivePath.hasPrefix("/") {
            effectivePath = "/" + effectivePath
        }

        let urlString = base + effectivePath
        // swiftlint:disable:next force_unwrapping
        return URL(string: urlString)!
    }

    // MARK: - Errors

    enum UpstreamError: Error {
        case invalidResponse
        case httpError(statusCode: Int, body: Data)
    }
}
