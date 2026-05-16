import ProxyPilotCore
import Testing
@testable import proxypilot

struct CLIStartModelResolverTests {
    @Test func localProviderWithoutExplicitModelsFetchesUpstreamModels() async throws {
        var capturedProvider: UpstreamProvider?
        var capturedBaseURL: String?
        var capturedAPIKey: String?

        let resolution = try await CLIStartModelResolver.resolve(
            rawModels: nil,
            provider: .ollama,
            upstreamURL: "http://192.168.1.50:11434/v1",
            apiKey: nil,
            discoverModels: { provider, baseURL, apiKey in
                capturedProvider = provider
                capturedBaseURL = baseURL
                capturedAPIKey = apiKey
                return ["qwen2.5-coder:0.5b", "codellama:13b"]
            }
        )

        #expect(resolution.models == ["qwen2.5-coder:0.5b", "codellama:13b"])
        #expect(resolution.wasDiscoveredFromUpstream)
        #expect(capturedProvider == .ollama)
        #expect(capturedBaseURL == "http://192.168.1.50:11434/v1")
        #expect(capturedAPIKey == nil)
    }

    @Test func explicitModelsBypassUpstreamDiscovery() async throws {
        let resolution = try await CLIStartModelResolver.resolve(
            rawModels: " qwen2.5-coder:0.5b, codellama:13b ",
            provider: .ollama,
            upstreamURL: "http://192.168.1.50:11434/v1",
            apiKey: nil,
            discoverModels: { _, _, _ in
                Issue.record("Explicit --model should not fetch upstream models.")
                return []
            }
        )

        #expect(resolution.models == ["qwen2.5-coder:0.5b", "codellama:13b"])
        #expect(!resolution.wasDiscoveredFromUpstream)
    }

    @Test func localProviderWithoutDiscoveredModelsThrowsActionableError() async {
        await #expect(throws: CLIStartModelResolver.ResolutionError.noModelsDiscovered(provider: .ollama, baseURL: "http://192.168.1.50:11434/v1")) {
            _ = try await CLIStartModelResolver.resolve(
                rawModels: nil,
                provider: .ollama,
                upstreamURL: "http://192.168.1.50:11434/v1",
                apiKey: nil,
                discoverModels: { _, _, _ in [] }
            )
        }
    }
}
