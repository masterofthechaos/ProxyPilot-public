import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import ProxyPilotCore

struct RouteIdentityTests {
    @Test func identityRequiresLocalAuthenticationAndNeverReturnsSecrets() async throws {
        let server = NIOProxyServer()
        let config = ProxyConfiguration(port: 0, upstreamProvider: .qwen,
            upstreamAPIBaseURL: "https://username:password@example.invalid/v1?secret=private#fragment",
            upstreamAPIKey: "upstream-secret", masterKey: "local-test-credential", allowedModels: ["test-model"],
            requiresAuth: true, preferredAnthropicUpstreamModel: "test-model", sessionID: "test-runtime")
        let port = try await server.start(config: config)
        do {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/proxypilot/route")!)
            let (_, unauthorized) = try await URLSession.shared.data(for: request)
            #expect((unauthorized as? HTTPURLResponse)?.statusCode == 401)
            request.setValue("Bearer local-test-credential", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            let identity = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
            #expect(identity == ["provider": "qwen", "model": "test-model", "endpoint": "https://example.invalid/v1", "session_id": "test-runtime"])
            request.setValue("https://evil.invalid", forHTTPHeaderField: "Origin")
            let (_, browser) = try await URLSession.shared.data(for: request)
            #expect((browser as? HTTPURLResponse)?.statusCode == 403)
            try await server.stop()
        } catch { try? await server.stop(); throw error }
    }
}
