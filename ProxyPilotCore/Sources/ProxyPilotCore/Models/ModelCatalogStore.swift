import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Non-secret provider metadata shared by GUI discovery and CLI routing.
public enum ModelCatalogStore {
    public struct Snapshot: Codable, Sendable {
        public let models: [UpstreamModel]
        public let fetchedAt: Date
        public var isStale: Bool { Date().timeIntervalSince(fetchedAt) > 3600 }
    }
    public static var directory: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
        return base.appendingPathComponent("proxypilot/catalogs", isDirectory: true)
    }
    private static func url(provider: String, endpoint: String, root: URL) -> URL {
        let identity = provider + "\n" + endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(key + ".json")
    }
    public static func model(id: String, provider: UpstreamProvider, snapshot: Snapshot?) -> UpstreamModel? {
        let baseID = id.hasSuffix(":exacto") ? String(id.dropLast(7)) : id
        let discovered = snapshot?.models.first { $0.id == id || $0.id == baseID }
        let known = provider.knownModelMetadata(for: id)
        guard let found = discovered else { return known }
        return UpstreamModel(id: id, contextLength: found.contextLength ?? known?.contextLength,
            promptPricePer1M: found.promptPricePer1M ?? known?.promptPricePer1M,
            completionPricePer1M: found.completionPricePer1M ?? known?.completionPricePer1M,
            promptCacheHitPricePer1M: found.promptCacheHitPricePer1M ?? known?.promptCacheHitPricePer1M,
            promptCacheMissPricePer1M: found.promptCacheMissPricePer1M ?? known?.promptCacheMissPricePer1M,
            promptCacheWritePricePer1M: found.promptCacheWritePricePer1M ?? known?.promptCacheWritePricePer1M,
            supportedParameters: found.supportedParameters.union(known?.supportedParameters ?? []),
            displayName: found.displayName, lab: found.lab, catalogAddedAt: found.catalogAddedAt,
            inputModalities: found.inputModalities ?? known?.inputModalities,
            outputModalities: found.outputModalities ?? known?.outputModalities,
            maximumOutputTokens: found.maximumOutputTokens ?? known?.maximumOutputTokens)
    }

    public static func save(_ models: [UpstreamModel], provider: String, endpoint: String, now: Date = Date(), root: URL = directory) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(Snapshot(models: models, fetchedAt: now))
        try data.write(to: url(provider: provider, endpoint: endpoint, root: root), options: .atomic)
    }
    public static func load(provider: String, endpoint: String, root: URL = directory) -> Snapshot? {
        guard let data = try? Data(contentsOf: url(provider: provider, endpoint: endpoint, root: root)) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
}
