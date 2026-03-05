import Foundation

public enum SecretsProviderFactory {
    public static let secretsDirectoryEnvVar = "PROXYPILOT_SECRETS_DIR"
    public static let keychainServiceEnvVar = "PROXYPILOT_KEYCHAIN_SERVICE"

    public static func make() -> any SecretsProvider {
        if let fileDirectory = overrideFileDirectory() {
            return FileSecretsProvider(directory: fileDirectory)
        }

        #if canImport(Security)
        let fallbackFileProvider = FileSecretsProvider()
        if let keychainService = overrideKeychainService() {
            return FallbackSecretsProvider(
                primary: KeychainSecretsProvider(service: keychainService),
                fallback: fallbackFileProvider
            )
        }
        return FallbackSecretsProvider(
            primary: KeychainSecretsProvider(),
            fallback: fallbackFileProvider
        )
        #else
        return FileSecretsProvider()
        #endif
    }

    private static func overrideFileDirectory() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment[secretsDirectoryEnvVar]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    #if canImport(Security)
    private static func overrideKeychainService() -> String? {
        guard let raw = ProcessInfo.processInfo.environment[keychainServiceEnvVar]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return raw
    }
    #endif
}
