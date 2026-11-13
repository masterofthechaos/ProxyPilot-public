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
    case invalidUpstreamURL(provider: UpstreamProvider, url: String, reason: String)
}

enum ProviderCredentialResolver {
    static func configuredProviderChoices(
        secrets: any SecretsProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [ProviderCredentialChoice] {
        var choices: [ProviderCredentialChoice] = []

        for provider in UpstreamProvider.allCases where provider.secretKey != nil {
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
        guard let secretKey = provider.secretKey else {
            return false
        }
        if let value = environment[secretKey], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return ((try? secrets.exists(key: secretKey)) == true)
    }

    static func validateUpstreamOverride(
        provider: UpstreamProvider,
        upstreamURL: String?
    ) -> ProviderCredentialResolution? {
        guard let upstreamURL else { return nil }

        switch classifyOverride(upstreamURL, provider: provider) {
        case .invalid(let reason):
            return .invalidUpstreamURL(provider: provider, url: upstreamURL, reason: reason)
        case .official, .localhost, .localNetwork:
            return nil
        }
    }

    private static func resolveExplicit(
        provider: UpstreamProvider,
        explicitKey: String?,
        upstreamURL: String?,
        secrets: any SecretsProvider,
        environment: [String: String],
        selectedFromStoredCredentials: Bool
    ) -> ProviderCredentialResolution {
        let overrideTrust: UpstreamOverrideTrust
        if let upstreamURL {
            overrideTrust = classifyOverride(upstreamURL, provider: provider)
            if case .invalid(let reason) = overrideTrust {
                return .invalidUpstreamURL(provider: provider, url: upstreamURL, reason: reason)
            }
        } else {
            overrideTrust = .official
        }

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
        let mayUseStoredCredential = upstreamURL == nil || overrideTrust == .official
        let apiKey: String? = if let explicitKey {
            explicitKey
        } else if mayUseStoredCredential, let secretKey {
            envKey ?? (try? secrets.get(key: secretKey))
        } else {
            nil
        }

        let effectiveBaseURL = upstreamURL ?? provider.preferredAPIBaseURL
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

    private enum UpstreamOverrideTrust: Equatable {
        case official
        case localhost
        case localNetwork
        case invalid(String)
    }

    private static func classifyOverride(_ upstreamURL: String, provider: UpstreamProvider) -> UpstreamOverrideTrust {
        let trimmedURL = upstreamURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            return .invalid("Upstream URL override must not be empty.")
        }
        guard let components = URLComponents(string: trimmedURL),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              !host.isEmpty else {
            return .invalid("Upstream URL override must be an HTTP(S) URL with a host.")
        }
        guard components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return .invalid("Upstream URL override must not include userinfo, query, or fragment components.")
        }

        if isLocalhostURL(trimmedURL) {
            return .localhost
        }
        if provider.isLocal, isPrivateNetworkURL(trimmedURL) {
            return .localNetwork
        }

        let trustedBaseURLs = [provider.defaultAPIBaseURL] + provider.alternateAPIBaseURLs
        guard let normalizedOverride = normalizedBaseURL(trimmedURL),
              trustedBaseURLs.compactMap(normalizedBaseURL).contains(normalizedOverride) else {
            return .invalid(
                "Upstream URL overrides must point to localhost, "
                    + "a private-network URL for local providers, "
                    + "or the selected provider's official API base URL."
            )
        }
        return .official
    }

    private static func isPrivateNetworkURL(_ rawURL: String) -> Bool {
        guard let host = URL(string: rawURL)?.host?.lowercased() else { return false }
        if host.hasSuffix(".local") { return true }
        if isPrivateIPv4(host) { return true }
        if host.contains(":"), host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80:") {
            return true
        }
        return false
    }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }

        if octets[0] == 10 { return true }
        if octets[0] == 172 && (16...31).contains(octets[1]) { return true }
        if octets[0] == 192 && octets[1] == 168 { return true }
        if octets[0] == 169 && octets[1] == 254 { return true }
        return false
    }

    private static func normalizedBaseURL(_ rawURL: String) -> String? {
        guard var components = URLComponents(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }
        components.scheme = scheme
        components.host = host
        var path = components.percentEncodedPath
        while path.hasSuffix("/") {
            path.removeLast()
        }
        components.percentEncodedPath = path.isEmpty ? "" : path
        return components.string
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
