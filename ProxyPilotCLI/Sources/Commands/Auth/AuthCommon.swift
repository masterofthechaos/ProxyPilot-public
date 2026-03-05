import Foundation
import ProxyPilotCore

struct AuthBackendInfo {
    let label: String
    let filePath: String?
}

func authBackendInfo(for secrets: any SecretsProvider) -> AuthBackendInfo {
    if let fallbackProvider = secrets as? FallbackSecretsProvider {
        let label = fallbackProvider.lastResolvedBackendLabel ?? "keychain+file-fallback"
        let path = label == "file" ? fallbackProvider.fallbackFileURL.path : nil
        return AuthBackendInfo(label: label, filePath: path)
    }
    if let fileProvider = secrets as? FileSecretsProvider {
        return AuthBackendInfo(label: "file", filePath: fileProvider.secretsFileURL.path)
    }
    #if canImport(Security)
    if secrets is KeychainSecretsProvider {
        return AuthBackendInfo(label: "keychain", filePath: nil)
    }
    #endif
    return AuthBackendInfo(label: "unknown", filePath: nil)
}
