import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import ProxyPilotCore

@Test func cloudCredentialRequiresLocalClientAuthentication() {
    #expect(LocalProxyCredential.requiresAuthentication(
        explicitlyRequired: false,
        upstreamAPIKey: "cloud-secret"
    ))
    #expect(LocalProxyCredential.requiresAuthentication(
        explicitlyRequired: true,
        upstreamAPIKey: nil
    ))
    #expect(!LocalProxyCredential.requiresAuthentication(
        explicitlyRequired: false,
        upstreamAPIKey: "  "
    ))
}

@Test func generatedLocalCredentialIsRandomLookingAndStable() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("proxypilot-local-credential-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = FileSecretsProvider(directory: directory)

    let first = try LocalProxyCredential.resolveOrCreate(using: secrets)
    let second = try LocalProxyCredential.resolveOrCreate(using: secrets)

    #expect(first == second)
    #expect(first.hasPrefix(LocalProxyCredential.generatedPrefix))
    #expect(first.count >= LocalProxyCredential.generatedPrefix.count + 40)
    #expect(first != "proxypilot")
    #expect(try secrets.get(key: SecretKey.masterKey) == first)
}

@Test func proxyConfigurationCannotDisableAuthWhileForwardingCredential() {
    let protected = ProxyConfiguration(
        upstreamAPIKey: "cloud-secret",
        masterKey: "local-capability",
        requiresAuth: false
    )
    let localAnonymous = ProxyConfiguration(
        upstreamProvider: .ollama,
        upstreamAPIKey: nil,
        masterKey: nil,
        requiresAuth: false
    )

    #expect(protected.requiresAuthForProtectedRoutes)
    #expect(!localAnonymous.requiresAuthForProtectedRoutes)
}

@Test func managedXcodeCredentialMigrationPreservesUnknownSettings() throws {
    let original = Data(#"{"env":{"ANTHROPIC_AUTH_TOKEN":"legacy","ANTHROPIC_BASE_URL":"http://127.0.0.1:4000","CUSTOM_ENV":"keep"},"customRoot":{"enabled":true}}"#.utf8)
    let migrated = try LocalProxyCredential.updatingManagedXcodeSettings(
        original,
        credential: "pp_local_new"
    )
    let updated = try #require(migrated)
    let root = try #require(JSONSerialization.jsonObject(with: updated) as? [String: Any])
    let environment = try #require(root["env"] as? [String: Any])
    let customRoot = try #require(root["customRoot"] as? [String: Any])

    #expect(environment["ANTHROPIC_AUTH_TOKEN"] as? String == "pp_local_new")
    #expect(environment["ANTHROPIC_BASE_URL"] as? String == "http://127.0.0.1:4000")
    #expect(environment["CUSTOM_ENV"] as? String == "keep")
    #expect(customRoot["enabled"] as? Bool == true)
}

@Test func managedXcodeCredentialMigrationSkipsUnmanagedOrCurrentDocuments() throws {
    let unmanaged = Data(#"{"customRoot":true}"#.utf8)
    let current = Data(#"{"env":{"ANTHROPIC_AUTH_TOKEN":"pp_local_current"}}"#.utf8)

    let unmanagedResult = try LocalProxyCredential.updatingManagedXcodeSettings(
        unmanaged,
        credential: "pp_local_new"
    )
    let currentResult = try LocalProxyCredential.updatingManagedXcodeSettings(
        current,
        credential: "pp_local_current"
    )

    #expect(unmanagedResult == nil)
    #expect(currentResult == nil)
}

private struct DeniedClientSecrets: SecretsProvider {
    func get(key: String) throws -> String? { throw SecretsError.fileError("denied") }
    func set(key: String, value: String) throws { throw SecretsError.fileError("denied") }
    func delete(key: String) throws { throw SecretsError.fileError("denied") }
    func list() throws -> [String] { throw SecretsError.fileError("denied") }
}

@Test func anonymousClientNeverAccessesSecretsButRequiredAndUnknownPoliciesDo() throws {
    let secrets = DeniedClientSecrets()
    #expect(try LocalProxyCredential.resolveForClient(authenticationRequired: false, using: secrets)
        == LocalProxyCredential.unauthenticatedClientToken)
    #expect(throws: SecretsError.self) {
        try LocalProxyCredential.resolveForClient(authenticationRequired: true, using: secrets)
    }
    #expect(throws: SecretsError.self) {
        try LocalProxyCredential.resolveForClient(authenticationRequired: nil, using: secrets)
    }
}

@Test(arguments: [UpstreamProvider.ollama, .lmStudio, .openRouter])
func clientProbeUsesEffectiveListenerAuthentication(provider: UpstreamProvider) async throws {
    for (explicitAuth, upstreamKey) in [(false, Optional<String>.none), (true, nil), (false, "upstream-fixture")] {
        let config = ProxyConfiguration(
            port: 0, upstreamProvider: provider, upstreamAPIKey: upstreamKey,
            masterKey: "local-fixture", allowedModels: ["fixture"], requiresAuth: explicitAuth
        )
        let server = NIOProxyServer()
        let port = try await server.start(config: config)
        let probe = await LocalProxyProbe.probe(on: port)
        let requiresAuth = explicitAuth || upstreamKey != nil
        #expect(probe.reachable)
        #expect(probe.authenticationRequired == requiresAuth)
        // A stale saved provider must not override the live listener's policy.
        let bootstrap = try await ProxyDaemonBootstrapper.ensureRunning(
            settings: AgentLaunchSettings(port: port, providerID: "ollama")
        )
        #expect(bootstrap.outcome == .alreadyRunning)
        #expect(bootstrap.authenticationRequired == requiresAuth)
        if requiresAuth {
            #expect(throws: SecretsError.self) {
                try LocalProxyCredential.resolveForClient(authenticationRequired: probe.authenticationRequired, using: DeniedClientSecrets())
            }
        } else {
            #expect(try LocalProxyCredential.resolveForClient(authenticationRequired: probe.authenticationRequired, using: DeniedClientSecrets())
                == LocalProxyCredential.unauthenticatedClientToken)
        }
        // The SDK placeholder must never gain access to either inference protocol.
        if requiresAuth {
            for path in ["v1/chat/completions", "v1/messages"] {
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/\(path)")!)
                request.httpMethod = "POST"
                request.httpBody = Data("{}".utf8)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(LocalProxyCredential.unauthenticatedClientToken)", forHTTPHeaderField: "Authorization")
                let (_, response) = try await URLSession.shared.data(for: request)
                #expect((response as? HTTPURLResponse)?.statusCode == 401)
            }
        }
        try await server.stop()
    }
}
