import ProxyPilotCore
import Testing
@testable import proxypilot

struct ProviderCredentialResolverTests {
    @Test func bareProviderWithOnlyZAIKeyResolvesToZAI() throws {
        let secrets = MemorySecretsProvider(values: [SecretKey.zaiAPIKey: "zai-key"])

        let resolution = ProviderCredentialResolver.resolve(
            rawProvider: nil,
            explicitKey: nil,
            upstreamURL: nil,
            secrets: secrets,
            environment: [:]
        )

        guard case .resolved(let credential) = resolution else {
            Issue.record("Expected resolver to choose the only configured provider.")
            return
        }
        #expect(credential.provider == .zAI)
        #expect(credential.apiKey == "zai-key")
        #expect(credential.selectedFromStoredCredentials)
    }

    @Test func explicitOpenAIStillRequiresOpenAIKey() throws {
        let secrets = MemorySecretsProvider(values: [SecretKey.zaiAPIKey: "zai-key"])

        let resolution = ProviderCredentialResolver.resolve(
            rawProvider: "openai",
            explicitKey: nil,
            upstreamURL: nil,
            secrets: secrets,
            environment: [:]
        )

        guard case .missingAPIKey(let provider, let secretKeyName) = resolution else {
            Issue.record("Expected explicit OpenAI selection to report missing OpenAI auth.")
            return
        }
        #expect(provider == .openAI)
        #expect(secretKeyName == SecretKey.openAIAPIKey)
    }

    @Test func multipleConfiguredProviderKeysRequireSelection() throws {
        let secrets = MemorySecretsProvider(values: [
            SecretKey.zaiAPIKey: "zai-key",
            SecretKey.openAIAPIKey: "openai-key",
        ])

        let resolution = ProviderCredentialResolver.resolve(
            rawProvider: nil,
            explicitKey: nil,
            upstreamURL: nil,
            secrets: secrets,
            environment: [:]
        )

        guard case .selectionRequired(let prompt) = resolution else {
            Issue.record("Expected multiple configured providers to require a selection.")
            return
        }
        #expect(prompt.availableProviders.map(\.provider).contains("zai"))
        #expect(prompt.availableProviders.map(\.provider).contains("openai"))
        #expect(prompt.humanList.contains("Z.ai (Key found)"))
        #expect(prompt.humanList.contains("Add new API key"))
        #expect(prompt.humanList.contains("Add new provider"))
    }

    @Test func environmentKeyCountsAsConfiguredProvider() throws {
        let secrets = MemorySecretsProvider(values: [:])

        let resolution = ProviderCredentialResolver.resolve(
            rawProvider: nil,
            explicitKey: nil,
            upstreamURL: nil,
            secrets: secrets,
            environment: [SecretKey.zaiAPIKey: "zai-env-key"]
        )

        guard case .resolved(let credential) = resolution else {
            Issue.record("Expected resolver to use provider credentials from environment.")
            return
        }
        #expect(credential.provider == .zAI)
        #expect(credential.apiKey == "zai-env-key")
    }

    @Test func emptyEnvironmentVariableReportsMissingAPIKey() throws {
        let secrets = MemorySecretsProvider(values: [:])

        let resolution = ProviderCredentialResolver.resolve(
            rawProvider: "zai",
            explicitKey: nil,
            upstreamURL: nil,
            secrets: secrets,
            environment: [SecretKey.zaiAPIKey: ""]
        )

        guard case .missingAPIKey(let provider, let secretKeyName) = resolution else {
            Issue.record("Expected an empty env var to be treated as no API key, not a started-but-broken proxy.")
            return
        }
        #expect(provider == .zAI)
        #expect(secretKeyName == SecretKey.zaiAPIKey)
    }

    @Test func whitespaceOnlyEnvironmentVariableReportsMissingAPIKey() throws {
        let secrets = MemorySecretsProvider(values: [:])

        let resolution = ProviderCredentialResolver.resolve(
            rawProvider: "openai",
            explicitKey: nil,
            upstreamURL: nil,
            secrets: secrets,
            environment: [SecretKey.openAIAPIKey: "   \n\t  "]
        )

        guard case .missingAPIKey(let provider, _) = resolution else {
            Issue.record("Expected a whitespace-only env var to be treated as no API key.")
            return
        }
        #expect(provider == .openAI)
    }

    @Test func emptyEnvironmentVariableFallsThroughToSecretsStore() throws {
        let secrets = MemorySecretsProvider(values: [SecretKey.zaiAPIKey: "stored-zai"])

        let resolution = ProviderCredentialResolver.resolve(
            rawProvider: "zai",
            explicitKey: nil,
            upstreamURL: nil,
            secrets: secrets,
            environment: [SecretKey.zaiAPIKey: ""]
        )

        guard case .resolved(let credential) = resolution else {
            Issue.record("Expected resolver to ignore empty env var and read the stored key.")
            return
        }
        #expect(credential.apiKey == "stored-zai")
    }
}

private struct MemorySecretsProvider: SecretsProvider {
    let values: [String: String]

    func get(key: String) throws -> String? {
        values[key]
    }

    func exists(key: String) throws -> Bool {
        values[key] != nil
    }

    func set(key _: String, value _: String) throws {}

    func delete(key _: String) throws {}

    func list() throws -> [String] {
        Array(values.keys)
    }
}
