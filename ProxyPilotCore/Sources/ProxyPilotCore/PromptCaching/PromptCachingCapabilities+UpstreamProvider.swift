import Foundation

extension UpstreamProvider {
    public var promptCacheCapabilities: PromptCacheCapabilities {
        switch self {
        case .openAI:
            return PromptCacheCapabilities(
                supportsAutomaticProviderCaching: true,
                supportsPromptCacheKey: true,
                supportsAnthropicCacheControl: false,
                supportsExplicitCacheObjects: false,
                supportsProviderCacheTelemetry: true
            )
        case .xAI:
            return PromptCacheCapabilities(
                supportsAutomaticProviderCaching: true,
                supportsPromptCacheKey: true,
                supportsAnthropicCacheControl: false,
                supportsExplicitCacheObjects: false,
                supportsProviderCacheTelemetry: true
            )
        case .mistral:
            return PromptCacheCapabilities(
                supportsAutomaticProviderCaching: true,
                supportsPromptCacheKey: true,
                supportsAnthropicCacheControl: false,
                supportsExplicitCacheObjects: false,
                supportsProviderCacheTelemetry: true
            )
        case .deepSeek:
            return PromptCacheCapabilities(
                supportsAutomaticProviderCaching: true,
                supportsPromptCacheKey: false,
                supportsAnthropicCacheControl: false,
                supportsExplicitCacheObjects: false,
                supportsProviderCacheTelemetry: true
            )
        case .zAI:
            return PromptCacheCapabilities(
                supportsAutomaticProviderCaching: true,
                supportsPromptCacheKey: false,
                supportsAnthropicCacheControl: false,
                supportsExplicitCacheObjects: false,
                supportsProviderCacheTelemetry: true
            )
        case .miniMax, .miniMaxCN:
            return PromptCacheCapabilities(
                supportsAutomaticProviderCaching: true,
                supportsPromptCacheKey: false,
                supportsAnthropicCacheControl: true,
                supportsExplicitCacheObjects: false,
                supportsProviderCacheTelemetry: true
            )
        case .google:
            return PromptCacheCapabilities(
                supportsAutomaticProviderCaching: true,
                supportsPromptCacheKey: false,
                supportsAnthropicCacheControl: false,
                supportsExplicitCacheObjects: true,
                supportsProviderCacheTelemetry: false,
                unsafeForMutationReason: "Google direct already has thought_signature state; explicit cache objects require a separate adapter."
            )
        default:
            return .none
        }
    }
}
