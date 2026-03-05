import Foundation

/// File-backed secrets provider for Linux and testing.
/// Stores secrets as JSON at a configurable path.
public final class FileSecretsProvider: SecretsProvider, @unchecked Sendable {
    private let filePath: URL
    private let lock = NSLock()

    public var secretsFileURL: URL { filePath }

    public init(directory: URL? = nil) {
        let dir = directory ?? FileSecretsProvider.defaultDirectory()
        self.filePath = dir.appendingPathComponent("secrets.json")
    }

    public func get(key: String) throws -> String? {
        let store = try load()
        return store[key]
    }

    public func set(key: String, value: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var store = (try? load()) ?? [:]
        store[key] = value
        try save(store)
    }

    public func delete(key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var store = (try? load()) ?? [:]
        store.removeValue(forKey: key)
        try save(store)
    }

    public func list() throws -> [String] {
        let store = try load()
        return Array(store.keys)
    }

    private func load() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: filePath.path) else { return [:] }
        let data = try Data(contentsOf: filePath)
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    private func save(_ store: [String: String]) throws {
        let dir = filePath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(store)
        try data.write(to: filePath, options: .atomic)
    }

    private static func defaultDirectory() -> URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] {
            return URL(fileURLWithPath: xdg).appendingPathComponent("proxypilot")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("proxypilot")
    }
}
