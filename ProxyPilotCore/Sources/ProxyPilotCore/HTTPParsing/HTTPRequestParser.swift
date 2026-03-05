import Foundation

/// Extracts testable HTTP parsing logic from LocalProxyServer.
/// This keeps the main server focused on networking while allowing unit tests for parsing.
public enum HTTPRequestParser {

    public struct ParsedRequest {
        public let method: String
        public let path: String
        public let headers: [String: String]
        public let contentLength: Int

        public init(method: String, path: String, headers: [String: String], contentLength: Int) {
            self.method = method
            self.path = path
            self.headers = headers
            self.contentLength = contentLength
        }
    }

    public enum ParseError: Error, Equatable {
        case emptyHeader
        case invalidRequestLine
        case missingMethod
    }

    /// Parses raw HTTP header data into a structured request.
    /// - Parameter headerData: The raw bytes up to (but not including) \r\n\r\n
    /// - Returns: A ParsedRequest with method, path, headers, and content-length
    public static func parse(headerData: Data) -> Result<ParsedRequest, ParseError> {
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .failure(.emptyHeader)
        }

        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            return .failure(.emptyHeader)
        }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            return .failure(.invalidRequestLine)
        }

        let method = String(parts[0])
        let rawPath = String(parts[1])
        let path = rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? rawPath

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let name = line[..<colonIndex]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let value = line[line.index(after: colonIndex)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        let contentLength = Int(headers["content-length"] ?? "") ?? 0

        return .success(ParsedRequest(
            method: method,
            path: path,
            headers: headers,
            contentLength: contentLength
        ))
    }

    /// Checks if a request body indicates streaming mode.
    public static func isStreamingRequest(body: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return false
        }
        return json["stream"] as? Bool == true
    }

    /// Extracts the model from a request body.
    public static func extractModel(from body: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        return json["model"] as? String
    }
}

/// Authorization validation logic extracted for testability.
public enum AuthorizationValidator {

    /// Checks if the request headers contain valid authorization.
    /// - Parameters:
    ///   - headers: Lowercase header dictionary
    ///   - masterKey: The expected master key/password
    /// - Returns: true if authorized
    public static func isAuthorized(headers: [String: String], masterKey: String) -> Bool {
        let candidates = [
            headers["authorization"],
            headers["x-api-key"],
            headers["api-key"]
        ]
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        for value in candidates {
            // Check Bearer token format
            if value.hasPrefix("Bearer ") {
                let token = value.dropFirst("Bearer ".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if token == masterKey { return true }
            }
            // Check raw key
            if value == masterKey { return true }
        }
        return false
    }
}

/// Model filtering logic extracted for testability.
public enum ModelFilter {

    /// Checks if a requested model is allowed.
    /// - Parameters:
    ///   - requestedModel: The model from the request
    ///   - allowedModels: Set of allowed model IDs (empty means allow all)
    /// - Returns: true if the model is allowed
    public static func isAllowed(_ requestedModel: String, in allowedModels: Set<String>) -> Bool {
        if allowedModels.isEmpty { return true }
        return allowedModels.contains(requestedModel)
    }
}
