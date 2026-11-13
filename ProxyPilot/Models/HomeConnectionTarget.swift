import Foundation

enum HomeConnectionTarget: String, CaseIterable, Identifiable {
    case xcode
    case repoGPS = "repogps"
    case epiphyte

    var id: Self { self }
    var title: String {
        switch self {
        case .xcode: "Xcode"
        case .repoGPS: "RepoGPS"
        case .epiphyte: "Epiphyte"
        }
    }
}

/// Frozen user intent survives a Home target change or another picker edit.
/// These are existing connection operations, never instructions from a model.
enum ConnectionModelSubmission: Sendable {
    case repoGPS(provider: String, model: String, port: Int)
    case epiphyte(provider: String, model: String)

    @MainActor
    func apply(repoGPS: RouteControlService, epiphyte: EpiphyteControlService) async {
        await perform(repoGPS: { provider, model, port in
            await repoGPS.applyRoute(provider: provider, model: model, port: port)
        }, epiphyte: { provider, model in
            await epiphyte.save(provider: provider, model: model)
        })
    }
    @MainActor
    func perform(repoGPS: (String, String, Int) async -> Void,
                 epiphyte: (String, String) async -> Void) async {
        switch self {
        case .repoGPS(let provider, let model, let port): await repoGPS(provider, model, port)
        case .epiphyte(let provider, let model): await epiphyte(provider, model)
        }
    }
}
