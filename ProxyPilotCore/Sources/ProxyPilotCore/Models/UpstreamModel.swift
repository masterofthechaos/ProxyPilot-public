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
    /// Full price of cache creation, not an added surcharge. Normalized cache
    /// misses include these tokens; priced writes replace their ordinary input
    /// charge rather than being billed a second time.
    public let promptCacheWritePricePer1M: Double?
    public let inputModalities: [String]?
    public let outputModalities: [String]?
    public let maximumOutputTokens: Int?
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
        catalogAddedAt: Date? = nil,
        inputModalities: [String]? = nil,
        outputModalities: [String]? = nil,
        maximumOutputTokens: Int? = nil
    ) {
        self.inputModalities = inputModalities
        self.outputModalities = outputModalities
        self.maximumOutputTokens = maximumOutputTokens
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
        case supportedParameters, displayName, lab, catalogAddedAt, inputModalities, outputModalities, maximumOutputTokens
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
            catalogAddedAt: try c.decodeIfPresent(Date.self, forKey: .catalogAddedAt),
            inputModalities: try c.decodeIfPresent([String].self, forKey: .inputModalities),
            outputModalities: try c.decodeIfPresent([String].self, forKey: .outputModalities),
            maximumOutputTokens: try c.decodeIfPresent(Int.self, forKey: .maximumOutputTokens)
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
            displayName: displayName, lab: lab, catalogAddedAt: catalogAddedAt,
            inputModalities: inputModalities, outputModalities: outputModalities, maximumOutputTokens: maximumOutputTokens
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

        if inputModalities?.contains("image") == true {
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
           promptCacheHitPricePer1M != nil || promptCacheMissPricePer1M != nil || promptCacheWritePricePer1M != nil {
            let sanitizedHitTokens = max(promptCacheHitTokens, 0)
            let sanitizedMissTokens = max(promptCacheMissTokens, 0)
            // Writes are a subset of normalized misses in both OpenAI-compatible
            // (prompt minus reads) and native Anthropic (input plus writes) usage.
            // Without a write price, retain the standard input estimate instead
            // of treating missing price metadata as a free cache write.
            let pricedWriteTokens = promptCacheWritePricePer1M == nil
                ? 0 : min(max(promptCacheWriteTokens ?? 0, 0), sanitizedMissTokens)
            let sanitizedCompletionTokens = max(completionTokens, 0)
            let hitCost = (Double(sanitizedHitTokens) / 1_000_000) * (promptCacheHitPricePer1M ?? promptPricePer1M ?? 0)
            let missCost = (Double(sanitizedMissTokens - pricedWriteTokens) / 1_000_000) * (promptCacheMissPricePer1M ?? promptPricePer1M ?? 0)
            let writeCost = (Double(pricedWriteTokens) / 1_000_000) * (promptCacheWritePricePer1M ?? 0)
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
