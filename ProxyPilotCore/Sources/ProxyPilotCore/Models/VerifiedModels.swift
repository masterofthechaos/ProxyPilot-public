import Foundation

public struct VerifiedModelEntry: Codable, Sendable {
    public let id: String
    public let note: String?

    public init(id: String, note: String?) {
        self.id = id
        self.note = note
    }
}

public struct VerifiedModels: Sendable {
    private let ids: Set<String>

    public init(entries: [VerifiedModelEntry]) {
        self.ids = Set(entries.map(\.id))
    }

    public var isEmpty: Bool { ids.isEmpty }

    public func contains(_ modelID: String) -> Bool {
        ids.contains(modelID)
    }

    /// Fetch from a remote URL. Returns empty array on failure.
    public static func fetchRemote(from url: URL) async -> [VerifiedModelEntry] {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            return (try? JSONDecoder().decode([VerifiedModelEntry].self, from: data)) ?? []
        } catch {
            return []
        }
    }

    /// Load with fallback chain: cache -> bundle -> empty.
    public static func loadCached(cacheURL: URL?, bundleURL: URL?) -> [VerifiedModelEntry] {
        if let cacheURL, let data = try? Data(contentsOf: cacheURL),
           let entries = try? JSONDecoder().decode([VerifiedModelEntry].self, from: data),
           !entries.isEmpty {
            return entries
        }
        if let bundleURL, let data = try? Data(contentsOf: bundleURL),
           let entries = try? JSONDecoder().decode([VerifiedModelEntry].self, from: data) {
            return entries
        }
        return []
    }

    /// Save entries to cache file.
    public static func saveCache(entries: [VerifiedModelEntry], to url: URL) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
