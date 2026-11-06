import Foundation

public struct UpstreamModel: Identifiable, Hashable, Sendable, Codable {
    public let displayName: String?
    public let lab: String?
    public let catalogAddedAt: Date?
    public let id: String
    public let contextLength: Int?
    public let promptPricePer1M: Double?
    public let completionPricePer1M: Double?
    public let promptCacheHitPricePer1M: Double?
    public let promptCacheMissPricePer1M: Double?
    /// Price of *writing* tokens into the provider's prompt cache. Distinct from the
    /// hit/miss pair: providers that charge a premium for cache creation bill these
    /// tokens once, on top of the uncached input they also count.
    public let promptCacheWritePricePer1M: Double?
    public let supportedParameters: Set<String>

    public init(
        id: String,
        contextLength: Int?,
        promptPricePer1M: Double?,
        completionPricePer1M: Double?,
        promptCacheHitPricePer1M: Double? = nil,
        promptCacheMissPricePer1M: Double? = nil,
        promptCacheWritePricePer1M: Double? = nil,
        supportedParameters: Set<String> = [],
        displayName: String? = nil,
        lab: String? = nil,
        catalogAddedAt: Date? = nil
    ) {
        self.displayName = displayName
        self.lab = lab
        self.catalogAddedAt = catalogAddedAt
        self.id = id
        self.contextLength = contextLength
        self.promptPricePer1M = promptPricePer1M.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.completionPricePer1M = completionPricePer1M.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.promptCacheHitPricePer1M = promptCacheHitPricePer1M.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.promptCacheMissPricePer1M = promptCacheMissPricePer1M.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.promptCacheWritePricePer1M = promptCacheWritePricePer1M.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.supportedParameters = supportedParameters
    }

    private enum CodingKeys: String, CodingKey {
        case id, contextLength, promptPricePer1M, completionPricePer1M
        case promptCacheHitPricePer1M, promptCacheMissPricePer1M, promptCacheWritePricePer1M
        case supportedParameters, displayName, lab, catalogAddedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            contextLength: try c.decodeIfPresent(Int.self, forKey: .contextLength),
            promptPricePer1M: try c.decodeIfPresent(Double.self, forKey: .promptPricePer1M),
            completionPricePer1M: try c.decodeIfPresent(Double.self, forKey: .completionPricePer1M),
            promptCacheHitPricePer1M: try c.decodeIfPresent(Double.self, forKey: .promptCacheHitPricePer1M),
            promptCacheMissPricePer1M: try c.decodeIfPresent(Double.self, forKey: .promptCacheMissPricePer1M),
            promptCacheWritePricePer1M: try c.decodeIfPresent(Double.self, forKey: .promptCacheWritePricePer1M),
            supportedParameters: try c.decodeIfPresent(Set<String>.self, forKey: .supportedParameters) ?? [],
            displayName: try c.decodeIfPresent(String.self, forKey: .displayName),
            lab: try c.decodeIfPresent(String.self, forKey: .lab),
            catalogAddedAt: try c.decodeIfPresent(Date.self, forKey: .catalogAddedAt)
        )
    }

    public static func idOnly(_ id: String) -> UpstreamModel {
        UpstreamModel(id: id, contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil)
    }

    public var baseIDWithoutExactoSuffix: String {
        id.hasSuffix(":exacto") ? String(id.dropLast(":exacto".count)) : id
    }

    public var exactoVariantID: String {
        baseIDWithoutExactoSuffix + ":exacto"
    }

    public var supportsToolCalling: Bool {
        supportedParameters.contains("tools") || supportedParameters.contains("tool_choice")
    }

    public var isExactoEligible: Bool {
        id.hasSuffix(":exacto") || supportsToolCalling
    }

    public var exactoVariant: UpstreamModel {
        UpstreamModel(
            id: exactoVariantID,
            contextLength: contextLength,
            promptPricePer1M: promptPricePer1M,
            completionPricePer1M: completionPricePer1M,
            promptCacheHitPricePer1M: promptCacheHitPricePer1M,
            promptCacheMissPricePer1M: promptCacheMissPricePer1M,
            promptCacheWritePricePer1M: promptCacheWritePricePer1M,
            supportedParameters: supportedParameters,
            displayName: displayName, lab: lab, catalogAddedAt: catalogAddedAt
        )
    }

    public var contextFormatted: String? {
        guard let ctx = contextLength, ctx > 0 else { return nil }
        if ctx >= 1_000_000 {
            let millions = Double(ctx) / 1_000_000
            if millions == millions.rounded() {
                return "\(Int(millions))M"
            }
            return String(format: "%.1fM", millions)
        }
        if ctx >= 1_000 {
            let thousands = Double(ctx) / 1_000
            if thousands == thousands.rounded() {
                return "\(Int(thousands))K"
            }
            return String(format: "%.1fK", thousands)
        }
        return "\(ctx)"
    }

    public var pricingTier: PricingTier {
        guard let prompt = promptPricePer1M else { return .unknown }
        if prompt <= 0 { return .free }
        if prompt < 1.0 { return .budget }
        if prompt < 10.0 { return .standard }
        return .premium
    }

    public var capabilities: Set<ModelCapability> {
        let lower = id.lowercased()
        var caps = Set<ModelCapability>()

        let reasoningKeywords = ["o1", "o3", "o4", "reasoning", "think", "deepseek-r1", "qwq"]
        if reasoningKeywords.contains(where: { lower.contains($0) }) {
            caps.insert(.reasoning)
        }

        let visionKeywords = ["vision", "vl", "4o", "gpt-4-turbo", "gemini"]
        if visionKeywords.contains(where: { lower.contains($0) }) {
            caps.insert(.vision)
        }

        let codingKeywords = ["code", "coder", "codestral", "starcoder", "deepseek-v"]
        if codingKeywords.contains(where: { lower.contains($0) }) {
            caps.insert(.coding)
        }

        if supportsToolCalling {
            caps.insert(.toolCalling)
        }

        return caps
    }

    public func estimatedCostUSD(promptTokens: Int, completionTokens: Int) -> Double? {
        estimatedCostUSD(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            promptCacheHitTokens: nil,
            promptCacheMissTokens: nil
        )
    }

    public func estimatedCostUSD(
        promptTokens: Int,
        completionTokens: Int,
        promptCacheHitTokens: Int?,
        promptCacheMissTokens: Int?,
        promptCacheWriteTokens: Int? = nil
    ) -> Double? {
        if let promptCacheHitTokens, let promptCacheMissTokens,
           promptCacheHitPricePer1M != nil || promptCacheMissPricePer1M != nil {
            let sanitizedHitTokens = max(promptCacheHitTokens, 0)
            let sanitizedMissTokens = max(promptCacheMissTokens, 0)
            let sanitizedWriteTokens = max(promptCacheWriteTokens ?? 0, 0)
            let sanitizedCompletionTokens = max(completionTokens, 0)
            let hitCost = (Double(sanitizedHitTokens) / 1_000_000) * (promptCacheHitPricePer1M ?? 0)
            let missCost = (Double(sanitizedMissTokens) / 1_000_000) * (promptCacheMissPricePer1M ?? promptPricePer1M ?? 0)
            // Cache creation is billed on top of the uncached input it accompanies, so
            // this is an additional term rather than a substitute for the miss cost.
            // Providers that do not charge for cache writes report no price and it
            // contributes nothing.
            let writeCost = (Double(sanitizedWriteTokens) / 1_000_000) * (promptCacheWritePricePer1M ?? 0)
            let completionCost = (Double(sanitizedCompletionTokens) / 1_000_000) * (completionPricePer1M ?? 0)
            return hitCost + missCost + writeCost + completionCost
        }

        guard promptPricePer1M != nil || completionPricePer1M != nil else { return nil }
        let sanitizedPromptTokens = max(promptTokens, 0)
        let sanitizedCompletionTokens = max(completionTokens, 0)

        let promptCost = (Double(sanitizedPromptTokens) / 1_000_000) * (promptPricePer1M ?? 0)
        let completionCost = (Double(sanitizedCompletionTokens) / 1_000_000) * (completionPricePer1M ?? 0)
        return promptCost + completionCost
    }

    public var pricingPerMillionLabel: String? {
        guard promptPricePer1M != nil
            || completionPricePer1M != nil
            || promptCacheHitPricePer1M != nil
            || promptCacheMissPricePer1M != nil else {
            return nil
        }
        let promptLabel: String
        if let hit = promptCacheHitPricePer1M, let miss = promptCacheMissPricePer1M {
            promptLabel = "\(Self.formatUSDCurrency(hit))/M cached · \(Self.formatUSDCurrency(miss))/M uncached"
        } else {
            promptLabel = promptPricePer1M.map { Self.formatUSDCurrency($0) + "/M" } ?? "-"
        }
        let completionLabel = completionPricePer1M.map { Self.formatUSDCurrency($0) } ?? "-"
        return "In \(promptLabel) · Out \(completionLabel)/M"
    }

    private static func formatUSDCurrency(_ amount: Double) -> String {
        if amount < 0.01 {
            return String(format: "$%.4f", amount)
        }
        if amount < 1 {
            return String(format: "$%.3f", amount)
        }
        return String(format: "$%.2f", amount)
    }
}

public enum PricingTier: String, Sendable {
    case free
    case budget
    case standard
    case premium
    case unknown

    public var label: String {
        switch self {
        case .free: return "Free"
        case .budget: return "$"
        case .standard: return "$$"
        case .premium: return "$$$"
        case .unknown: return ""
        }
    }
}

public enum ModelCapability: String, Hashable, Sendable {
    case toolCalling
    case reasoning
    case vision
    case coding

    public var label: String {
        switch self {
        case .toolCalling: return "Tools"
        default: return rawValue.capitalized
        }
    }
}
