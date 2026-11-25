import Foundation

/// Whether a local provider currently has a model in memory, and with how
/// much context.
///
/// An OpenAI-compatible `/v1/models` list names every downloaded model and
/// says nothing about this. LM Studio answers it on its own REST API.
public struct LocalModelLoadState: Sendable, Equatable {
    public let modelID: String
    public let isLoaded: Bool
    /// Context the loaded instance was given. Nil while not loaded.
    public let loadedContextLength: Int?
    /// The largest context the model supports.
    public let maxContextLength: Int?

    public init(modelID: String, isLoaded: Bool, loadedContextLength: Int? = nil, maxContextLength: Int? = nil) {
        self.modelID = modelID
        self.isLoaded = isLoaded
        self.loadedContextLength = loadedContextLength
        self.maxContextLength = maxContextLength
    }

    /// A short status for display beside the model.
    public func summary(providerTitle: String) -> String {
        guard isLoaded else {
            return "Not loaded in \(providerTitle). The first request will load it with \(providerTitle)'s default context length, which may be too small; load it there with the context you need."
        }
        switch (loadedContextLength, maxContextLength) {
        case let (loaded?, max?):
            return "Loaded with a \(Self.grouped(loaded))-token context (model maximum \(Self.grouped(max)))."
        case let (loaded?, nil):
            return "Loaded with a \(Self.grouped(loaded))-token context."
        default:
            return "Loaded."
        }
    }

    private static func grouped(_ value: Int) -> String { UpstreamFailureReport.grouped(value) }
}

/// Reads model load state from LM Studio's REST API (`GET /api/v0/models`).
public enum LMStudioModelState {
    /// The load-state URL for an LM Studio OpenAI-compatible base such as
    /// `http://localhost:1234/v1`: same origin, LM Studio's own API path.
    public static func modelsURL(apiBase: String) -> URL? {
        guard var components = URLComponents(string: apiBase),
              components.scheme != nil, components.host != nil else { return nil }
        components.path = "/api/v0/models"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// Load state by model id. Entries without an id or a recognized state
    /// are skipped, so an unknown answer is absent instead of "not loaded".
    public static func parse(_ data: Data) -> [String: LocalModelLoadState] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]] else { return [:] }
        var states: [String: LocalModelLoadState] = [:]
        for entry in entries {
            guard let id = entry["id"] as? String, !id.isEmpty,
                  let state = entry["state"] as? String else { continue }
            let isLoaded: Bool
            switch state {
            case "loaded": isLoaded = true
            case "not-loaded": isLoaded = false
            default: continue
            }
            states[id] = LocalModelLoadState(
                modelID: id,
                isLoaded: isLoaded,
                loadedContextLength: isLoaded ? (entry["loaded_context_length"] as? NSNumber)?.intValue : nil,
                maxContextLength: (entry["max_context_length"] as? NSNumber)?.intValue
            )
        }
        return states
    }
}
