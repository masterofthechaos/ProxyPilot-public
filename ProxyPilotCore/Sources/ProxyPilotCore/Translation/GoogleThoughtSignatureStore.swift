import Foundation

public final class GoogleThoughtSignatureStore: @unchecked Sendable {
    private struct Entry {
        let signature: String
        let insertedAt: Date
    }

    private let lock = NSLock()
    private let ttl: TimeInterval
    private let maxEntries: Int
    private var entries: [String: Entry] = [:]
    private var insertionOrder: [String] = []

    public init(ttl: TimeInterval = 300, maxEntries: Int = 1_000) {
        self.ttl = ttl
        self.maxEntries = maxEntries
    }

    public func store(signature: String, for toolCallID: String) {
        guard !signature.isEmpty, !toolCallID.isEmpty else { return }
        let now = Date()

        lock.lock()
        defer { lock.unlock() }

        pruneExpired(now: now)
        entries[toolCallID] = Entry(signature: signature, insertedAt: now)
        insertionOrder.removeAll { $0 == toolCallID }
        insertionOrder.append(toolCallID)
        pruneCapacity()
    }

    public func lookup(toolCallID: String) -> String? {
        guard !toolCallID.isEmpty else { return nil }
        let now = Date()

        lock.lock()
        defer { lock.unlock() }

        if let entry = entries[toolCallID], now.timeIntervalSince(entry.insertedAt) <= ttl {
            return entry.signature
        }

        pruneExpired(now: now)
        return nil
    }

    public func remove(toolCallID: String) {
        lock.lock()
        defer { lock.unlock() }

        entries.removeValue(forKey: toolCallID)
        insertionOrder.removeAll { $0 == toolCallID }
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }

        entries.removeAll()
        insertionOrder.removeAll()
    }

    private func pruneExpired(now: Date) {
        let expiredKeys = entries.compactMap { key, entry in
            now.timeIntervalSince(entry.insertedAt) > ttl ? key : nil
        }
        guard !expiredKeys.isEmpty else { return }

        let expiredSet = Set(expiredKeys)
        for key in expiredKeys {
            entries.removeValue(forKey: key)
        }
        insertionOrder.removeAll { expiredSet.contains($0) }
    }

    private func pruneCapacity() {
        while entries.count > maxEntries, let oldestKey = insertionOrder.first {
            insertionOrder.removeFirst()
            entries.removeValue(forKey: oldestKey)
        }
    }
}
