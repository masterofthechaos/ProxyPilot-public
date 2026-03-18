import Foundation

public struct UpstreamModel: Identifiable, Hashable, Sendable {
    public let id: String
    public let contextLength: Int?
    public let promptPricePer1M: Double?
    public let completionPricePer1M: Double?

    public init(id: String, contextLength: Int?, promptPricePer1M: Double?, completionPricePer1M: Double?) {
        self.id = id
        self.contextLength = contextLength
        self.promptPricePer1M = promptPricePer1M
        self.completionPricePer1M = completionPricePer1M
    }

    public static func idOnly(_ id: String) -> UpstreamModel {
        UpstreamModel(id: id, contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil)
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

        return caps
    }

    public func estimatedCostUSD(promptTokens: Int, completionTokens: Int) -> Double? {
        guard promptPricePer1M != nil || completionPricePer1M != nil else { return nil }
        let sanitizedPromptTokens = max(promptTokens, 0)
        let sanitizedCompletionTokens = max(completionTokens, 0)

        let promptCost = (Double(sanitizedPromptTokens) / 1_000_000) * (promptPricePer1M ?? 0)
        let completionCost = (Double(sanitizedCompletionTokens) / 1_000_000) * (completionPricePer1M ?? 0)
        return promptCost + completionCost
    }

    public var pricingPerMillionLabel: String? {
        guard promptPricePer1M != nil || completionPricePer1M != nil else { return nil }
        let promptLabel = promptPricePer1M.map { Self.formatUSDCurrency($0) } ?? "-"
        let completionLabel = completionPricePer1M.map { Self.formatUSDCurrency($0) } ?? "-"
        return "In \(promptLabel)/M · Out \(completionLabel)/M"
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
    case reasoning
    case vision
    case coding

    public var label: String {
        rawValue.capitalized
    }
}
