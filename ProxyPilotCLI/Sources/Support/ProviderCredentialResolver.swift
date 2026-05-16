import Foundation
import ProxyPilotCore

struct ProviderCredentialChoice: Encodable, Equatable {
    let index: Int
    let provider: String
    let title: String
    let status: String
}

struct ProviderSelectionPrompt: Encodable, Equatable {
    let availableProviders: [ProviderCredentialChoice]
    let addNewAPIKeyIndex: Int
    let addNewProviderIndex: Int

    enum CodingKeys: String, CodingKey {
        case availableProviders = "available_providers"
        case addNewAPIKeyIndex = "add_new_api_key_index"
        case addNewProviderIndex = "add_new_provider_index"
    }

    var humanList: String {
        var lines: [String] = ["Available current providers:"]
        for choice in availableProviders {
            lines.append("\(choice.index). \(choice.title) (\(choice.status))")
        }
        lines.append("\(addNewAPIKeyIndex). Add new API key")
        lines.append("\(addNewProviderIndex). Add new provider")
        return lines.joined(separator: "\n")
    }
}

struct ResolvedProviderCredential {
    let provider: UpstreamProvider
    let apiKey: String?
    let secretKeyName: String?
    let selectedFromStoredCredentials: Bool
}

enum ProviderCredentialResolution {
    case resolved(ResolvedProviderCredential)
    case selectionRequired(ProviderSelectionPrompt)
    case unknownProvider(String)
    case missingAPIKey(provider: UpstreamProvider, secretKeyName: String?)
}

enum ProviderCredentialResolver {
    static func configuredProviderChoices(
        secrets: any SecretsProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [ProviderCredentialChoice] {
        var choices: [ProviderCredentialChoice] = []

        for provider in UpstreamProvider.allCases where provider.requiresAPIKey {
            guard hasCredential(for: provider, secrets: secrets, environment: environment) else { continue }
            choices.append(ProviderCredentialChoice(
                index: choices.count + 1,
                provider: provider.rawValue,
                title: providerSelectionTitle(provider),
                status: "Key found"
            ))
        }

        return choices
    }

    static func selectionPrompt(
        secrets: any SecretsProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ProviderSelectionPrompt {
        let choices = configuredProviderChoices(secrets: secrets, environment: environment)
        return ProviderSelectionPrompt(
            availableProviders: choices,
            addNewAPIKeyIndex: choices.count + 1,
            addNewProviderIndex: choices.count + 2
        )
    }

    static func resolve(
        rawProvider: String?,
        explicitKey: String?,
        upstreamURL: String?,
        secrets: any SecretsProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ProviderCredentialResolution {
        if let rawProvider {
            guard let provider = UpstreamProvider(rawValue: rawProvider) else {
                return .unknownProvider(rawProvider)
            }
            return resolveExplicit(
                provider: provider,
                explicitKey: explicitKey,
                upstreamURL: upstreamURL,
                secrets: secrets,
                environment: environment,
                selectedFromStoredCredentials: false
            )
        }

        let choices = configuredProviderChoices(secrets: secrets, environment: environment)
        guard choices.count == 1,
              let provider = UpstreamProvider(rawValue: choices[0].provider) else {
            return .selectionRequired(selectionPrompt(secrets: secrets, environment: environment))
        }

        return resolveExplicit(
            provider: provider,
            explicitKey: explicitKey,
            upstreamURL: upstreamURL,
            secrets: secrets,
            environment: environment,
            selectedFromStoredCredentials: true
        )
    }

    static func resolveSelection(
        choiceIndex: Int,
        prompt: ProviderSelectionPrompt,
        explicitKey: String?,
        upstreamURL: String?,
        secrets: any SecretsProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ProviderCredentialResolution {
        if let choice = prompt.availableProviders.first(where: { $0.index == choiceIndex }),
           let provider = UpstreamProvider(rawValue: choice.provider) {
            return resolveExplicit(
                provider: provider,
                explicitKey: explicitKey,
                upstreamURL: upstreamURL,
                secrets: secrets,
                environment: environment,
                selectedFromStoredCredentials: true
            )
        }

        return .selectionRequired(prompt)
    }

    static func hasCredential(
        for provider: UpstreamProvider,
        secrets: any SecretsProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard provider.requiresAPIKey, let secretKey = provider.secretKey else {
            return false
        }
        if let value = environment[secretKey], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return ((try? secrets.exists(key: secretKey)) == true)
    }

    private static func resolveExplicit(
        provider: UpstreamProvider,
        explicitKey: String?,
        upstreamURL: String?,
        secrets: any SecretsProvider,
        environment: [String: String],
        selectedFromStoredCredentials: Bool
    ) -> ProviderCredentialResolution {
        let secretKey = provider.secretKey
        // Mirror hasCredential's trim-and-reject: a stale `export VAR=` in the
        // user's shell would otherwise short-circuit nil-coalescing with an
        // empty string and bypass the missingAPIKey guard below, leaving the
        // proxy with an empty Bearer token.
        let envKey: String? = secretKey.flatMap { key in
            guard let raw = environment[key],
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return raw
        }
        let apiKey: String? = if let explicitKey {
            explicitKey
        } else if let secretKey {
            envKey ?? (try? secrets.get(key: secretKey))
        } else {
            nil
        }

        let effectiveBaseURL = upstreamURL ?? provider.defaultAPIBaseURL
        if apiKey == nil && !provider.isLocal && !isLocalhostURL(effectiveBaseURL) {
            return .missingAPIKey(provider: provider, secretKeyName: secretKey)
        }

        return .resolved(ResolvedProviderCredential(
            provider: provider,
            apiKey: apiKey,
            secretKeyName: secretKey,
            selectedFromStoredCredentials: selectedFromStoredCredentials
        ))
    }

    private static func providerSelectionTitle(_ provider: UpstreamProvider) -> String {
        switch provider {
        case .zAI:
            return "Z.ai"
        default:
            return provider.title
        }
    }
}
