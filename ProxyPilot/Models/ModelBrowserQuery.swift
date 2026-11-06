import Foundation
import ProxyPilotCore

/// Pure catalog filtering: favorites never bypass the user's filters.
struct ModelBrowserQuery {
    enum Sort: String, CaseIterable, Identifiable {
        case newest = "Newest", name = "Name", context = "Context size"
        case inputPrice = "Input price", outputPrice = "Output price"
        var id: Self { self }
    }
    var search = ""
    var labs: Set<String> = []
    var favoritesOnly = false
    var priceTier: PricingTier = .unknown
    var sort: Sort = .newest

    func results(_ models: [UpstreamModel], favorites: Set<String>) -> [UpstreamModel] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return models.filter { model in
            (query.isEmpty || model.id.localizedCaseInsensitiveContains(query)
                || (model.displayName?.localizedCaseInsensitiveContains(query) == true))
            && (labs.isEmpty || labs.contains(model.lab ?? "Unknown"))
            && (!favoritesOnly || favorites.contains(model.id))
            && (priceTier == .unknown || model.pricingTier == priceTier)
        }.sorted { a, b in
            func ordered(_ lhs: Double?, _ rhs: Double?, descending: Bool) -> Bool {
                switch (lhs, rhs) {
                case let (l?, r?) where l != r: return descending ? l > r : l < r
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.id < b.id
                }
            }
            switch sort {
            case .newest: return ordered(a.catalogAddedAt?.timeIntervalSince1970, b.catalogAddedAt?.timeIntervalSince1970, descending: true)
            case .context: return ordered(a.contextLength.map(Double.init), b.contextLength.map(Double.init), descending: true)
            case .inputPrice: return ordered(a.promptPricePer1M, b.promptPricePer1M, descending: false)
            case .outputPrice: return ordered(a.completionPricePer1M, b.completionPricePer1M, descending: false)
            case .name:
                let lhs = a.displayName ?? a.id, rhs = b.displayName ?? b.id
                return lhs == rhs ? a.id < b.id : lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
        }
    }
}
