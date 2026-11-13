import Foundation
import MCP
import ProxyPilotCore

enum MCPArgumentValidation<Value: Equatable>: Equatable {
    case success(Value)
    case failure(code: String, message: String)

    func isFailure(code expectedCode: String) -> Bool {
        guard case .failure(let code, _) = self else { return false }
        return code == expectedCode
    }
}

enum MCPArgumentValidator {
    static func port(
        _ raw: Value?,
        default defaultPort: UInt16,
        tool _: String,
        allowZero: Bool = true
    ) -> MCPArgumentValidation<UInt16> {
        guard let raw else {
            return .success(defaultPort)
        }

        guard let value = raw.intValue, let parsedPort = UInt16(exactly: value) else {
            return .failure(
                code: "E030",
                message: "Invalid port argument. Expected integer \(allowZero ? "0 or " : "")1024-65535."
            )
        }

        if parsedPort == 0 && allowZero {
            return .success(parsedPort)
        }

        guard parsedPort >= 1024 else {
            return .failure(
                code: "E030",
                message: "Invalid port \(parsedPort). Use \(allowZero ? "1024-65535, or 0 for auto-assign" : "1024-65535")."
            )
        }

        return .success(parsedPort)
    }

    static func provider(_ raw: String, tool _: String) -> MCPArgumentValidation<UpstreamProvider> {
        guard let provider = UpstreamProvider(rawValue: raw) else {
            return .failure(code: "E001", message: "Unknown provider: \(raw).")
        }
        return .success(provider)
    }

    static func provider(_ raw: Value?, default defaultProvider: String, tool: String) -> MCPArgumentValidation<UpstreamProvider> {
        guard let raw else {
            return provider(defaultProvider, tool: tool)
        }

        guard let value = raw.stringValue else {
            return .failure(code: "E001", message: "Invalid provider argument. Expected provider string.")
        }

        return provider(value, tool: tool)
    }

    static func optionalProvider(_ raw: Value?, tool: String) -> MCPArgumentValidation<UpstreamProvider?> {
        guard let raw else {
            return .success(nil)
        }

        guard let value = raw.stringValue else {
            return .failure(code: "E001", message: "Invalid provider argument. Expected provider string.")
        }

        switch provider(value, tool: tool) {
        case .success(let provider):
            return .success(provider)
        case .failure(let code, let message):
            return .failure(code: code, message: message)
        }
    }

    static func modelFilter(_ raw: String?, tool _: String) -> MCPArgumentValidation<String?> {
        guard let raw else {
            return .success(nil)
        }

        guard ModelSummaryBuilder.Filter(rawValue: raw) != nil else {
            return .failure(
                code: "E034",
                message: "Invalid model filter: \(raw). Use exacto, verified, tool-calling, or chat."
            )
        }

        return .success(raw)
    }

    static func modelFilter(_ raw: Value?, tool: String) -> MCPArgumentValidation<String?> {
        guard let raw else {
            return .success(nil)
        }

        guard let value = raw.stringValue else {
            return .failure(
                code: "E034",
                message: "Invalid model filter argument. Expected string filter: exacto, verified, tool-calling, or chat."
            )
        }

        return modelFilter(value, tool: tool)
    }

    static func bool(
        _ raw: Value?,
        default defaultValue: Bool,
        name: String,
        tool _: String
    ) -> MCPArgumentValidation<Bool> {
        guard let raw else {
            return .success(defaultValue)
        }

        guard let value = raw.boolValue else {
            return .failure(code: "E035", message: "Invalid \(name) argument. Expected boolean.")
        }

        return .success(value)
    }

    static func string(
        _ raw: Value?,
        default defaultValue: String?,
        name: String,
        tool _: String
    ) -> MCPArgumentValidation<String?> {
        guard let raw else {
            return .success(defaultValue)
        }

        guard let value = raw.stringValue else {
            return .failure(code: "E035", message: "Invalid \(name) argument. Expected string.")
        }

        return .success(value)
    }

    static func lineCount(
        _ raw: Value?,
        default defaultValue: Int,
        name: String,
        tool _: String,
        range: ClosedRange<Int> = 1...1_000
    ) -> MCPArgumentValidation<Int> {
        guard let raw else {
            return .success(defaultValue)
        }

        guard let value = raw.intValue else {
            return .failure(code: "E035", message: "Invalid \(name) argument. Expected integer.")
        }

        guard range.contains(value) else {
            return .failure(
                code: "E036",
                message: "Invalid \(name) \(value). Use \(range.lowerBound)-\(range.upperBound)."
            )
        }

        return .success(value)
    }

    static func modelDiscoveryBaseURL(
        _ raw: String?,
        provider: UpstreamProvider,
        tool _: String
    ) -> MCPArgumentValidation<String> {
        guard let raw else {
            return .success(provider.preferredAPIBaseURL)
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(code: "E036", message: "Invalid url argument. Expected an approved provider base URL.")
        }

        guard let candidate = normalizedBaseURL(trimmed) else {
            return .failure(code: "E036", message: "Invalid url argument. Expected an absolute http(s) provider base URL with no userinfo, query, or fragment.")
        }

        let approvedURLs = [provider.defaultAPIBaseURL] + provider.alternateAPIBaseURLs
        let approved = approvedURLs.compactMap(normalizedBaseURL)
        guard approved.contains(candidate) else {
            return .failure(
                code: "E036",
                message: "Unsafe url override for \(provider.rawValue). list_upstream_models only uses the provider's approved model endpoints."
            )
        }

        return .success(trimmed)
    }

    private static func normalizedBaseURL(_ raw: String) -> String? {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }

        components.scheme = scheme
        components.host = host
        var path = components.percentEncodedPath
        while path.hasSuffix("/") {
            path.removeLast()
        }
        components.percentEncodedPath = path.isEmpty ? "" : path
        return components.string
    }
}
