import Foundation

struct VerifiedModelEntry: Codable, Sendable {
    let id: String
    let note: String?
}

struct VerifiedModels: Sendable {
    private let ids: Set<String>

    init(entries: [VerifiedModelEntry]) {
        self.ids = Set(entries.map(\.id))
    }

    var isEmpty: Bool { ids.isEmpty }

    func contains(_ modelID: String) -> Bool {
        ids.contains(modelID)
    }

    /// Fetch from a remote URL. Returns empty array on failure.
    static func fetchRemote(from url: URL) async -> [VerifiedModelEntry] {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            return (try? JSONDecoder().decode([VerifiedModelEntry].self, from: data)) ?? []
        } catch {
            return []
        }
    }

    /// Load with fallback chain: cache -> bundle -> empty.
    static func loadCached(cacheURL: URL?, bundleURL: URL?) -> [VerifiedModelEntry] {
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
    static func saveCache(entries: [VerifiedModelEntry], to url: URL) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
