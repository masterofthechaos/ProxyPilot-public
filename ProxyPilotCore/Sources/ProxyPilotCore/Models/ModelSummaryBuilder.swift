import Foundation

public enum ModelSummaryBuilder {
    public enum Filter: String {
        case exacto
        case verified
        case toolCalling = "tool-calling"
        case chat
    }

    public static func summaries(ids: [String], verified: VerifiedModels) -> [ModelSummary] {
        ids.map { id in
            let model = UpstreamModel.idOnly(id)
            let supportsToolCalling = model.supportsToolCalling || inferredToolCallingSupport(for: id)
            let caps = model.capabilities.map { capability in
                capability == .toolCalling ? "tool_calling" : capability.rawValue
            }.sorted()
            let finalCaps = supportsToolCalling && !caps.contains("tool_calling")
                ? (caps + ["tool_calling"]).sorted()
                : caps

            return ModelSummary(
                id: id,
                contextLength: model.contextLength,
                pricingTier: model.pricingTier.rawValue,
                capabilities: finalCaps,
                verified: verified.contains(id),
                exactoEligible: model.isExactoEligible || supportsToolCalling,
                recommendedForXcodeAgent: supportsToolCalling && !isLegacyCompletionModel(id),
                toolCalling: .init(
                    supported: supportsToolCalling,
                    confidence: model.supportsToolCalling ? "declared" : "inferred"
                )
            )
        }
    }

    public static func apply(
        filter: String?,
        ids: [String],
        summaries: [ModelSummary],
        verified: VerifiedModels
    ) -> ([String], [ModelSummary]) {
        guard let filter, let parsed = Filter(rawValue: filter) else {
            return (ids, summaries)
        }

        switch parsed {
        case .exacto:
            let filtered = ModelDiscovery.filterExacto(ids)
            return (filtered, Self.summaries(ids: filtered, verified: verified))
        case .verified:
            let filtered = ModelDiscovery.filterVerified(ids, verified: verified)
            return (filtered, summaries.filter { filtered.contains($0.id) })
        case .toolCalling:
            let filteredSummaries = summaries.filter { $0.toolCalling.supported }
            return (filteredSummaries.map(\.id), filteredSummaries)
        case .chat:
            let filteredSummaries = summaries.filter { !isLegacyCompletionModel($0.id) }
            return (filteredSummaries.map(\.id), filteredSummaries)
        }
    }

    private static func inferredToolCallingSupport(for id: String) -> Bool {
        let lower = id.lowercased()
        return lower.contains("gpt-4")
            || lower.contains("gpt-5")
            || lower.contains("claude")
            || lower.contains("gemini")
            || lower.contains("glm")
    }

    private static func isLegacyCompletionModel(_ id: String) -> Bool {
        let lower = id.lowercased()
        return lower.contains("instruct")
            || lower.contains("davinci")
            || lower.contains("babbage")
    }
}
