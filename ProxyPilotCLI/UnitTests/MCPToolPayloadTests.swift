import Foundation
import ProxyPilotCore
import Testing
@testable import proxypilot

struct MCPToolPayloadTests {
    @Test func sessionStatsPayloadEncodesStructuredFieldsForAgents() throws {
        let payload = SessionStatsToolPayload(
            requests: 2,
            totalTokens: 30,
            promptTokens: 10,
            completionTokens: 20,
            averageLatencyMs: 123,
            uptimeSeconds: 9,
            models: ["glm-5.1": 2],
            promptCacheHitTokens: 4,
            promptCacheMissTokens: 6,
            promptCacheWriteTokens: 3,
            cacheHitRate: 0.4,
            cacheAccountingAvailable: true
        )

        let json = try AgentJSON.encode(payload)
        let data = Data(json.utf8)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["requests"] as? Int == 2)
        #expect(object["total_tokens"] as? Int == 30)
        #expect(object["prompt_tokens"] as? Int == 10)
        #expect(object["completion_tokens"] as? Int == 20)
        #expect(object["average_latency_ms"] as? Int == 123)
        #expect(object["uptime_seconds"] as? Int == 9)
        #expect((object["models"] as? [String: Int])?["glm-5.1"] == 2)
        #expect(object["prompt_cache_hit_tokens"] as? Int == 4)
        #expect(object["prompt_cache_miss_tokens"] as? Int == 6)
        #expect(object["prompt_cache_write_tokens"] as? Int == 3)
        #expect(object["cache_hit_rate"] as? Double == 0.4)
        #expect(object["cache_accounting_available"] as? Bool == true)
    }

    @Test func proxyStopPlanDoesNotSuggestConfigRemovalWhenConfigIsNotInstalled() {
        let plan = MCPStopResponsePlanner.plan(configInstalled: false)

        #expect(plan.text == "ProxyPilot stopped. Xcode config is not installed.")
        #expect(plan.nextActions.isEmpty)
    }

    @Test func proxyStopPlanSuggestsConfigRemovalWhenConfigIsInstalled() {
        let plan = MCPStopResponsePlanner.plan(configInstalled: true)

        #expect(plan.text.contains("Xcode config is still installed"))
        #expect(plan.nextActions.map(\.tool) == ["xcode_config_remove"])
        #expect(plan.nextActions.allSatisfy { $0.destructive })
    }

    @Test func statusProbeUsesRequestedPortWhenNoManagedPortExists() {
        let port = MCPStatusPortResolver.probePort(currentPort: nil, requestedPort: 4024)

        #expect(port == 4024)
    }

    @Test func statusProbeUsesManagedPortWhenProxyIsRunning() {
        let port = MCPStatusPortResolver.probePort(currentPort: 4025, requestedPort: 4024)

        #expect(port == 4025)
    }
}
