import Foundation

public struct PromptCacheCapabilities: Sendable, Equatable {
    public var supportsAutomaticProviderCaching: Bool
    public var supportsPromptCacheKey: Bool
    public var supportsAnthropicCacheControl: Bool
    public var supportsExplicitCacheObjects: Bool
    public var supportsProviderCacheTelemetry: Bool
    public var unsafeForMutationReason: String?

    public init(
        supportsAutomaticProviderCaching: Bool,
        supportsPromptCacheKey: Bool,
        supportsAnthropicCacheControl: Bool,
        supportsExplicitCacheObjects: Bool,
        supportsProviderCacheTelemetry: Bool,
        unsafeForMutationReason: String? = nil
    ) {
        self.supportsAutomaticProviderCaching = supportsAutomaticProviderCaching
        self.supportsPromptCacheKey = supportsPromptCacheKey
        self.supportsAnthropicCacheControl = supportsAnthropicCacheControl
        self.supportsExplicitCacheObjects = supportsExplicitCacheObjects
        self.supportsProviderCacheTelemetry = supportsProviderCacheTelemetry
        self.unsafeForMutationReason = unsafeForMutationReason
    }

    public static let none = PromptCacheCapabilities(
        supportsAutomaticProviderCaching: false,
        supportsPromptCacheKey: false,
        supportsAnthropicCacheControl: false,
        supportsExplicitCacheObjects: false,
        supportsProviderCacheTelemetry: false
    )
}
