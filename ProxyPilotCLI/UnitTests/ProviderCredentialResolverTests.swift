import ArgumentParser
import ProxyPilotCore
import Testing
@testable import proxypilot

struct ProviderCredentialResolverTests {
    @Test func qwenTokenPlanEndpointsCanUseStoredQwenCredential() {
        let secrets = MemorySecretsProvider(values: [SecretKey.qwenAPIKey: "sk-sp-fixture-not-a-real-key"])
        for endpoint in UpstreamProvider.qwen.alternateAPIBaseURLs {
            let resolution = ProviderCredentialResolver.resolve(rawProvider: "qwen", explicitKey: nil,
                upstreamURL: endpoint, secrets: secrets, environment: [:])
            guard case .resolved(let credential) = resolution else {
                Issue.record("Official Qwen service rejected")
                continue
            }
            #expect(credential.provider == .qwen)
            #expect(credential.apiKey == "sk-sp-fixture-not-a-real-key")
        }
    }

    @Test func discoveryAndSetupDoNotInventAProvider() throws {
        #expect(try ModelsCommand.parse([]).provider == nil)
        #expect(try SetupXcodeCommand.parse([]).provider == nil)
        #expect(try ModelsCommand.parse(["--provider", "ollama"]).provider == "ollama")
    }

    @Test func unknownPreflightProviderDoesNotOfferStartOrAuthActions() async {
        let (report, actions) = await AgentPreflightService.report(port: 4000, provider: "not-a-provider", model: nil)
        #expect(!report.ready)
        #expect(report.provider == "not-a-provider")
        #expect(report.blockers.first?.code == "E001")
        #expect(actions.isEmpty)
    }

    @Test func cerebrasRequiresItsOwnKeyAndOMLXAcceptsOptionalStoredKey() {
        let empty = MemorySecretsProvider(values: [:])
        let missing = ProviderCredentialResolver.resolve(rawProvider: "cerebras", explicitKey: nil,
            upstreamURL: nil, secrets: empty, environment: [:])
        guard case .missingAPIKey(let provider, let keyName) = missing else {
            Issue.record("Cerebras must require its own credential")
            return
        }
        #expect(provider == .cerebras)
        #expect(keyName == SecretKey.cerebrasAPIKey)
        for key in [nil, "omlx-fixture"] as [String?] {
            let secrets = MemorySecretsProvider(values: key.map { [SecretKey.omlxAPIKey: $0] } ?? [:])
            let result = ProviderCredentialResolver.resolve(rawProvider: "omlx", explicitKey: nil,
                upstreamURL: nil, secrets: secrets, environment: [:])
            guard case .resolved(let credential) = result else {
                Issue.record("oMLX must allow keyless inference and optional authenticated inference")
                return
            }
            #expect(credential.provider == .omlx)
            #expect(credential.apiKey == key)
        }
    }

    @Test func dnsLoopbackLookalikeCannotBypassOfficialEndpointPolicy() {
        let secrets = MemorySecretsProvider(values: [SecretKey.openAIAPIKey: "fixture-only"])
        let resolution = ProviderCredentialResolver.resolve(
            rawProvider: "openai", explicitKey: nil,
            upstreamURL: "https://127.attacker.example/v1", secrets: secrets, environment: [:]
        )
        guard case .invalidUpstreamURL = resolution else {
            Issue.record("A DNS lookalike must not be accepted as localhost")
            return
        }
    }

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

    @Test func explicit9RouterUsesOptionalStoredEndpointKey() throws {
        let secrets = MemorySecretsProvider(values: [SecretKey.nineRouterAPIKey: "router-key"])

        let resolution = ProviderCredentialResolver.resolve(
            rawProvider: "9router",
            explicitKey: nil,
            upstreamURL: nil,
            secrets: secrets,
            environment: [:]
        )

        guard case .resolved(let credential) = resolution else {
            Issue.record("Expected 9Router to resolve with its optional stored endpoint key.")
            return
        }
        #expect(credential.provider == .nineRouter)
        #expect(credential.apiKey == "router-key")
        #expect(credential.secretKeyName == SecretKey.nineRouterAPIKey)
    }

    @Test func explicit9RouterDoesNotRequireEndpointKey() throws {
        let secrets = MemorySecretsProvider(values: [:])

        let resolution = ProviderCredentialResolver.resolve(
            rawProvider: "9router",
            explicitKey: nil,
            upstreamURL: nil,
            secrets: secrets,
            environment: [:]
        )

        guard case .resolved(let credential) = resolution else {
            Issue.record("Expected 9Router to resolve without an endpoint key.")
            return
        }
        #expect(credential.provider == .nineRouter)
        #expect(credential.apiKey == nil)
        #expect(credential.secretKeyName == SecretKey.nineRouterAPIKey)
    }

    @Test func remoteOverrideRejectsStoredProviderKey() throws {
        let secrets = MemorySecretsProvider(values: [SecretKey.openAIAPIKey: "stored-openai-key"])

        let resolution = ProviderCredentialResolver.resolve(
            rawProvider: "openai",
            explicitKey: nil,
            upstreamURL: "https://attacker.example/v1",
            secrets: secrets,
            environment: [:]
        )

        guard case .invalidUpstreamURL(let provider, let url, let reason) = resolution else {
            Issue.record("Expected remote override to be rejected before reading stored OpenAI auth.")
            return
        }
        #expect(provider == .openAI)
        #expect(url == "https://attacker.example/v1")
        #expect(reason.contains("localhost"))
        #expect(reason.contains("official API base URL"))
    }

    @Test func localhostOverrideDoesNotReuseStoredProviderKey() throws {
        let secrets = MemorySecretsProvider(values: [SecretKey.openAIAPIKey: "stored-openai-key"])

        let resolution = ProviderCredentialResolver.resolve(
            rawProvider: "openai",
            explicitKey: nil,
            upstreamURL: "http://127.0.0.1:11434/v1",
            secrets: secrets,
            environment: [:]
        )

        guard case .resolved(let credential) = resolution else {
            Issue.record("Expected localhost override to remain available without cloud credentials.")
            return
        }
        #expect(credential.provider == .openAI)
        #expect(credential.apiKey == nil)
    }

    @Test func officialOverrideCanUseStoredProviderKey() throws {
        let secrets = MemorySecretsProvider(values: [SecretKey.openAIAPIKey: "stored-openai-key"])

        let resolution = ProviderCredentialResolver.resolve(
            rawProvider: "openai",
            explicitKey: nil,
            upstreamURL: "https://api.openai.com/v1/",
            secrets: secrets,
            environment: [:]
        )

        guard case .resolved(let credential) = resolution else {
            Issue.record("Expected official OpenAI override to use the stored OpenAI key.")
            return
        }
        #expect(credential.provider == .openAI)
        #expect(credential.apiKey == "stored-openai-key")
    }

    @Test func localProviderPrivateNetworkOverrideRemainsAllowedWithoutStoredKeyReuse() throws {
        let secrets = MemorySecretsProvider(values: [SecretKey.nineRouterAPIKey: "stored-router-key"])

        let resolution = ProviderCredentialResolver.resolve(
            rawProvider: "9router",
            explicitKey: nil,
            upstreamURL: "http://192.168.1.50:20128/v1",
            secrets: secrets,
            environment: [:]
        )

        guard case .resolved(let credential) = resolution else {
            Issue.record("Expected private-network local provider override to remain available.")
            return
        }
        #expect(credential.provider == .nineRouter)
        #expect(credential.apiKey == nil)
    }

    @Test func nonHTTPSchemeOverrideIsRejected() throws {
        let secrets = MemorySecretsProvider(values: [SecretKey.openAIAPIKey: "stored-openai-key"])

        let resolution = ProviderCredentialResolver.resolve(
            rawProvider: "openai",
            explicitKey: nil,
            upstreamURL: "file:///tmp/fake/v1",
            secrets: secrets,
            environment: [:]
        )

        guard case .invalidUpstreamURL(let provider, _, let reason) = resolution else {
            Issue.record("Expected non-HTTP(S) upstream override to be rejected.")
            return
        }
        #expect(provider == .openAI)
        #expect(reason.contains("HTTP(S) URL"))
    }

    @Test func upstreamOverrideRejectsUserinfoQueryAndFragment() throws {
        let secrets = MemorySecretsProvider(values: [SecretKey.openAIAPIKey: "stored-openai-key"])
        let unsafeURLs = [
            "https://user:secret@api.openai.com/v1",
            "https://api.openai.com/v1?target=https://attacker.example",
            "https://api.openai.com/v1#https://attacker.example",
        ]

        for unsafeURL in unsafeURLs {
            let resolution = ProviderCredentialResolver.resolve(
                rawProvider: "openai",
                explicitKey: nil,
                upstreamURL: unsafeURL,
                secrets: secrets,
                environment: [:]
            )

            guard case .invalidUpstreamURL(let provider, let url, let reason) = resolution else {
                Issue.record("Expected unsafe override to be rejected: \(unsafeURL)")
                continue
            }
            #expect(provider == .openAI)
            #expect(url == unsafeURL)
            #expect(reason.contains("userinfo, query, or fragment"))
        }
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
