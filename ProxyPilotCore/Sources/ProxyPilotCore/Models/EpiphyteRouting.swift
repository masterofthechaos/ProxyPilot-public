import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct EpiphyteRoute: Codable, Equatable, Sendable {
    public var provider: String
    public var model: String
    public var updatedAt: Date
    public init(provider: String, model: String, updatedAt: Date = Date()) {
        self.provider = provider; self.model = model; self.updatedAt = updatedAt
    }
}

/// Separate future-request preference. Never owns or starts the shared proxy.
public struct EpiphyteRouteStore: Sendable {
    public let directory: URL
    public static var defaultDirectory: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] {
            return URL(fileURLWithPath: xdg).appendingPathComponent("proxypilot")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/proxypilot")
    }
    public init(directory: URL = Self.defaultDirectory) { self.directory = directory }
    public var selectionURL: URL { directory.appendingPathComponent("epiphyte-route.json") }
    public func load() -> EpiphyteRoute? {
        guard let data = try? Data(contentsOf: selectionURL) else { return nil }
        return try? JSONDecoder().decode(EpiphyteRoute.self, from: data)
    }
    public func save(_ route: EpiphyteRoute) throws {
        try withLock { try write(route) }
    }
    /// Preserve previous Epi behavior once, without coupling later selections.
    public func loadOrSeed(_ previous: EpiphyteRoute?) throws -> EpiphyteRoute? {
        try withLock {
            if FileManager.default.fileExists(atPath: selectionURL.path) { return load() }
            if let previous { try write(previous) }
            return previous
        }
    }
    private func write(_ route: EpiphyteRoute) throws {
        guard UpstreamProvider(rawValue: route.provider) != nil,
              !route.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try JSONEncoder().encode(route).write(to: selectionURL, options: .atomic)
    }
    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appendingPathComponent("epiphyte-route.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

public struct IndependentRequestActivity: Codable, Equatable, Sendable {
    public var sessionID: String
    public var provider: String
    public var model: String
    public var startedAt: Date
    public init(sessionID: String, provider: String, model: String, startedAt: Date = Date()) {
        self.sessionID = sessionID; self.provider = provider; self.model = model; self.startedAt = startedAt
    }
}

/// An OS-held lease, not a timeout heuristic. Crash/kill releases the lock, so an
/// abandoned JSON file is never sufficient evidence of a running request.
public final class EpiphyteRequestLease {
    private let url: URL
    private var descriptor: Int32
    public static func activityDirectory(root: URL = EpiphyteRouteStore.defaultDirectory) -> URL {
        root.appendingPathComponent("independent-requests/epiphyte")
    }
    public init(_ activity: IndependentRequestActivity, root: URL = EpiphyteRouteStore.defaultDirectory) throws {
        let directory = Self.activityDirectory(root: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        url = directory.appendingPathComponent(UUID().uuidString + ".json")
        descriptor = open(url.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); descriptor = -1; throw CocoaError(.fileWriteUnknown) }
        do {
            let data = try JSONEncoder().encode(activity)
            try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(contentsOf: data)
        } catch {
            flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1
            try? FileManager.default.removeItem(at: url); throw error
        }
    }
    deinit {
        if descriptor >= 0 {
            flock(descriptor, LOCK_UN); close(descriptor)
            try? FileManager.default.removeItem(at: url)
        }
    }
    public static func active(root: URL = EpiphyteRouteStore.defaultDirectory) -> [IndependentRequestActivity] {
        let files = (try? FileManager.default.contentsOfDirectory(at: activityDirectory(root: root), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return nil }
            guard errno == EWOULDBLOCK || errno == EAGAIN else { return nil }
            guard let data = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() else { return nil }
            return try? JSONDecoder().decode(IndependentRequestActivity.self, from: data)
        }.sorted { $0.startedAt < $1.startedAt }
    }
}
