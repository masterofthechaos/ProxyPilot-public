import Foundation

public enum APIKeyValidationResult: Equatable, Sendable {
    case success
    case failure(code: String, message: String)
}

public enum APIKeyValidator {
    public static func validate(_ key: String, for provider: UpstreamProvider) -> APIKeyValidationResult {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)

        if provider == .zAI && trimmed.count < 20 {
            return .failure(
                code: "E046",
                message: "Z.ai API keys must be at least 20 characters long."
            )
        }

        return .success
    }
}
