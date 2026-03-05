import Foundation
import Testing
@testable import ProxyPilotCore

@Suite("GoogleThoughtSignatureStore")
struct GoogleThoughtSignatureStoreTests {
    @Test func lookupReturnsStoredSignature() {
        let store = GoogleThoughtSignatureStore()
        store.store(signature: "sig_1", for: "call_1")
        #expect(store.lookup(toolCallID: "call_1") == "sig_1")
    }

    @Test func capacityEvictsOldestEntry() {
        let store = GoogleThoughtSignatureStore(ttl: 300, maxEntries: 2)
        store.store(signature: "sig_1", for: "call_1")
        store.store(signature: "sig_2", for: "call_2")
        store.store(signature: "sig_3", for: "call_3")

        #expect(store.lookup(toolCallID: "call_1") == nil)
        #expect(store.lookup(toolCallID: "call_2") == "sig_2")
        #expect(store.lookup(toolCallID: "call_3") == "sig_3")
    }

    @Test func expiredEntriesArePrunedOnLookup() {
        let store = GoogleThoughtSignatureStore(ttl: 0.01, maxEntries: 10)
        store.store(signature: "sig_1", for: "call_1")
        Thread.sleep(forTimeInterval: 0.03)
        #expect(store.lookup(toolCallID: "call_1") == nil)
    }
}
