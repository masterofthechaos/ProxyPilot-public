import Foundation
import Testing
@testable import proxypilot

struct LifecycleGateTests {
    @Test func lifecycleGateSerializesConcurrentOperations() async throws {
        let gate = LifecycleGate()
        let probe = ConcurrencyProbe()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await gate.withLock {
                        await probe.enter()
                        try? await Task.sleep(for: .milliseconds(10))
                        await probe.leave()
                    }
                }
            }
        }

        let maxActive = await probe.maxActive
        #expect(maxActive == 1)
    }
}

private actor ConcurrencyProbe {
    private(set) var maxActive = 0
    private var active = 0

    func enter() {
        active += 1
        maxActive = max(maxActive, active)
    }

    func leave() {
        active -= 1
    }
}

