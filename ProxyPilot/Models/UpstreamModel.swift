import Foundation

struct UpstreamModel: Identifiable, Hashable, Sendable {
    let id: String
    let contextLength: Int?
    let promptPricePer1M: Double?
    let completionPricePer1M: Double?

    static func idOnly(_ id: String) -> UpstreamModel {
        UpstreamModel(id: id, contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil)
    }

    var contextFormatted: String? {
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

    var pricingTier: PricingTier {
        guard let prompt = promptPricePer1M else { return .unknown }
        if prompt <= 0 { return .free }
        if prompt < 1.0 { return .budget }
        if prompt < 10.0 { return .standard }
        return .premium
    }

    var capabilities: Set<ModelCapability> {
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
}

enum PricingTier: String, Sendable {
    case free
    case budget
    case standard
    case premium
    case unknown

    var label: String {
        switch self {
        case .free: return "Free"
        case .budget: return "$"
        case .standard: return "$$"
        case .premium: return "$$$"
        case .unknown: return ""
        }
    }
}

enum ModelCapability: String, Hashable, Sendable {
    case reasoning
    case vision
    case coding

    var label: String {
        rawValue.capitalized
    }
}
