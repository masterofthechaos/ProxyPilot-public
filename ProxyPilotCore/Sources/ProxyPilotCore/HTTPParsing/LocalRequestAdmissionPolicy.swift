import Foundation

public struct LocalHTTPHeaderField: Equatable, Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// Admission policy for ProxyPilot's native-only loopback HTTP API.
///
/// This is deliberately separate from client authentication. It blocks browser
/// origins, authority confusion, and simple no-CORS media types while preserving
/// ordinary passwordless native clients for local-model routes.
public enum LocalRequestAdmissionPolicy {
    public struct Rejection: Equatable, Sendable {
        public let statusCode: Int
        public let message: String

        public init(statusCode: Int, message: String) {
            self.statusCode = statusCode
            self.message = message
        }
    }

    public static func rejection(
        method: String,
        requestTarget: String,
        headers: [LocalHTTPHeaderField],
        listenerPort: UInt16
    ) -> Rejection? {
        guard requestTarget.hasPrefix("/"), !requestTarget.hasPrefix("//") else {
            return Rejection(statusCode: 400, message: "Unsupported request target")
        }

        let hostValues = values(named: "host", in: headers)
        guard hostValues.count == 1 else {
            return Rejection(statusCode: 400, message: "Exactly one Host header is required")
        }
        guard isAllowedLoopbackAuthority(hostValues[0], listenerPort: listenerPort) else {
            return Rejection(statusCode: 403, message: "Host is not this loopback listener")
        }

        if !values(named: "origin", in: headers).isEmpty
            || !values(named: "sec-fetch-site", in: headers).isEmpty {
            return Rejection(statusCode: 403, message: "Browser-origin requests are not allowed")
        }

        let path = requestTarget
            .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? requestTarget
        let isInferencePOST = method.caseInsensitiveCompare("POST") == .orderedSame
            && ["/v1/chat/completions", "/chat/completions", "/v1/messages"].contains(path)
        if isInferencePOST {
            let contentTypes = values(named: "content-type", in: headers)
            guard contentTypes.count == 1,
                  mediaType(from: contentTypes[0]) == "application/json" else {
                return Rejection(statusCode: 415, message: "Inference requests require application/json")
            }
        }

        return nil
    }

    private static func values(
        named name: String,
        in headers: [LocalHTTPHeaderField]
    ) -> [String] {
        headers.compactMap { field in
            field.name.caseInsensitiveCompare(name) == .orderedSame
                ? field.value.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
        }
    }

    private static func mediaType(from contentType: String) -> String {
        contentType
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private static func isAllowedLoopbackAuthority(
        _ rawAuthority: String,
        listenerPort: UInt16
    ) -> Bool {
        let authority = rawAuthority.lowercased()
        let expectedPort = listenerPort == 0 ? nil : String(listenerPort)
        if authority.hasPrefix("localhost:") {
            let port = String(authority.dropFirst("localhost:".count))
            return isAllowedPort(port, expected: expectedPort)
        }
        if authority.hasPrefix("[::1]:") {
            let port = String(authority.dropFirst("[::1]:".count))
            return isAllowedPort(port, expected: expectedPort)
        }

        let pieces = authority.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              isAllowedPort(String(pieces[1]), expected: expectedPort) else { return false }
        let octets = pieces[0].split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets[0] == "127" else { return false }
        return octets.allSatisfy { octet in
            guard let value = UInt8(octet) else { return false }
            return String(value) == octet || octet == "0"
        }
    }

    /// Port zero asks the operating system to choose the bound port. The HTTP
    /// handler receives that pre-bind configuration, so it may accept any valid
    /// explicit port while still requiring an exact loopback host.
    private static func isAllowedPort(_ rawPort: String, expected: String?) -> Bool {
        guard let port = UInt16(rawPort), port > 0, String(port) == rawPort else {
            return false
        }
        return expected == nil || rawPort == expected
    }
}
