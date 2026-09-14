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
        let request = try buildRequest(
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
        #if canImport(FoundationNetworking)
        // swift-corelibs-foundation has no `URLSession.bytes(for:)`; stream via
        // a data-delegate bridge that re-chunks to one line per yield, matching
        // the contract consumers rely on ("each chunk is one line").
        return AsyncThrowingStream { continuation in
            let request: URLRequest
            do {
                request = try buildRequest(
                    path: path, method: method, headers: headers, body: body, config: config)
            } catch {
                continuation.finish(throwing: error)
                return
            }
            let bridge = LineStreamingBridge(continuation: continuation)
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 300
            let session = URLSession(configuration: config, delegate: bridge, delegateQueue: nil)
            let task = session.dataTask(with: request)
            continuation.onTermination = { _ in
                task.cancel()
                session.finishTasksAndInvalidate()
            }
            task.resume()
        }
        #else
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let request = try buildRequest(
                        path: path,
                        method: method,
                        headers: headers,
                        body: body,
                        config: config
                    )

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
        #endif
    }

    #if canImport(FoundationNetworking)
    /// Bridges URLSessionDataDelegate callbacks into an AsyncThrowingStream,
    /// buffering partial lines so each yield is a complete newline-terminated
    /// line. Error statuses (>= 400) accumulate the body and finish by
    /// throwing `UpstreamError.httpError`, mirroring the Darwin path.
    private final class LineStreamingBridge: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private static let maximumBufferedLineBytes = 1_048_576
        private static let maximumErrorBodyBytes = 1_048_576
        private let continuation: AsyncThrowingStream<Data, Error>.Continuation
        private var buffer = Data()
        private var errorBody = Data()
        private var statusCode = 200

        init(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
            self.continuation = continuation
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            if let http = response as? HTTPURLResponse {
                statusCode = http.statusCode
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard statusCode < 400 else {
                let remaining = max(0, Self.maximumErrorBodyBytes - errorBody.count)
                errorBody.append(data.prefix(remaining))
                if data.count > remaining {
                    dataTask.cancel()
                    continuation.finish(throwing: UpstreamError.invalidResponse)
                }
                return
            }
            buffer.append(data)
            guard buffer.count <= Self.maximumBufferedLineBytes else {
                dataTask.cancel()
                continuation.finish(throwing: UpstreamError.invalidResponse)
                return
            }
            while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let afterNewline = buffer.index(after: newlineIndex)
                continuation.yield(buffer.subdata(in: buffer.startIndex..<afterNewline))
                buffer.removeSubrange(buffer.startIndex..<afterNewline)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                continuation.finish(throwing: error)
            } else if statusCode >= 400 {
                continuation.finish(throwing: UpstreamError.httpError(
                    statusCode: statusCode,
                    body: errorBody
                ))
            } else {
                if !buffer.isEmpty {
                    continuation.yield(buffer)
                }
                continuation.finish()
            }
            session.finishTasksAndInvalidate()
        }
    }
    #endif

    // MARK: - Private Helpers

    /// URLSession with a reasonable connection timeout for upstream requests.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        #if !canImport(FoundationNetworking)
        // Short connection timeout so tests against unreachable hosts fail fast.
        // Get-only (and a no-op) on swift-corelibs-foundation, so Darwin-only.
        config.waitsForConnectivity = false
        #endif
        return URLSession(configuration: config)
    }()

    static func buildRequest(
        path: String,
        method: String,
        headers: [(String, String)],
        body: Data?,
        config: ProxyConfiguration
    ) throws -> URLRequest {
        let upstreamURL = try buildUpstreamURL(
            path: path,
            config: config
        )

        var request = URLRequest(url: upstreamURL)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30

        // Forward relevant headers, excluding auth headers (we set our own)
        // and any client API key headers that could leak to the upstream provider.
        let skipHeaders: Set<String> = [
            "authorization",
            "host",
            "content-length",
            "x-api-key",
            "api-key",
            TutorRequestAdapter.headerName.lowercased(),
        ]
        for (name, value) in headers {
            if skipHeaders.contains(name.lowercased()) { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }

        applyJSONDefaults(body: body, request: &request)
        // Set upstream auth
        if let apiKey = config.upstreamAPIKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        return request
    }

    private static func applyJSONDefaults(body: Data?, request: inout URLRequest) {
        guard body != nil else { return }

        if request.value(forHTTPHeaderField: "Content-Type") == nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let existingAccept = request.value(forHTTPHeaderField: "Accept")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if existingAccept == nil || existingAccept == "" || existingAccept == "*/*" {
            let accept = isStreamingRequestBody(body) ? "text/event-stream" : "application/json"
            request.setValue(accept, forHTTPHeaderField: "Accept")
        }
    }

    private static func isStreamingRequestBody(_ body: Data?) -> Bool {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return false
        }
        return json["stream"] as? Bool == true
    }

    static func buildUpstreamURL(
        path: String,
        config: ProxyConfiguration
    ) throws -> URL {
        var base = config.upstreamAPIBaseURL
        while base.hasSuffix("/") {
            base.removeLast()
        }
        var effectivePath = path
        if !effectivePath.hasPrefix("/") {
            effectivePath = "/" + effectivePath
        }

        let urlString = base + effectivePath
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            throw ProxyEngineError.invalidUpstreamURL
        }
        return url
    }

    // MARK: - Errors

    enum UpstreamError: Error {
        case invalidResponse
        case httpError(statusCode: Int, body: Data)
    }
}
