import Foundation

/// A local client capability, distinct from every upstream provider credential.
///
/// Cloud credentials automatically require this capability on protected proxy
/// routes. Managed clients receive it through their generated configuration so
/// routine use remains passwordless without making account-backed inference
/// available to every process that can reach loopback.
public enum LocalProxyCredential {
    public static let generatedPrefix = "pp_local_"
    public static let randomByteCount = 32

    public static func requiresAuthentication(
        explicitlyRequired: Bool,
        upstreamAPIKey: String?
    ) -> Bool {
        explicitlyRequired || !(upstreamAPIKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ?? true)
    }

    public static func resolveOrCreate(using secrets: any SecretsProvider) throws -> String {
        if let existing = try secrets.get(key: SecretKey.masterKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }

        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<randomByteCount).map { _ in
            UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        }
        let token = generatedPrefix + Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        try secrets.set(key: SecretKey.masterKey, value: token)
        return token
    }

    /// Replaces only ProxyPilot's managed token in an existing Xcode Agent
    /// settings object. Unknown root and environment keys survive upgrades.
    /// Returns nil when the document is not the managed JSON shape or already
    /// contains the requested credential.
    public static func updatingManagedXcodeSettings(
        _ data: Data,
        credential: String
    ) throws -> Data? {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var environment = root["env"] as? [String: Any] else {
            return nil
        }
        if environment["ANTHROPIC_AUTH_TOKEN"] as? String == credential {
            return nil
        }
        environment["ANTHROPIC_AUTH_TOKEN"] = credential
        root["env"] = environment
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
    }
}
