import Foundation
import Network

enum PreflightCheckStatus: String, Codable {
    case pass
    case info
    case warning
    case fail
}

enum PreflightFixAction: String, Codable {
    case openMasterKeyEditor
    case openUpstreamKeyEditor
    case resetProxyURL
    case switchToBuiltInProxy
    case resetUpstreamURL
    case usePort4001
    case none
}

struct PreflightCheckResult: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let detail: String
    let status: PreflightCheckStatus
    let fixAction: PreflightFixAction
}

struct PreflightContext: Equatable {
    let proxyURLString: String
    let useBuiltInProxy: Bool
    let requireLocalAuth: Bool
    let upstreamAPIBaseURLString: String
    let fallbackUpstreamBaseURLString: String
    let hasMasterKey: Bool
    let hasUpstreamKey: Bool
    let liteLLMScriptsExist: Bool
}

struct ProxyURLValidation: Equatable {
    let url: URL
    let host: String
    let port: Int
}

@MainActor
final class PreflightService {
    private let proxyService: ProxyService

    init(proxyService: ProxyService = ProxyService()) {
        self.proxyService = proxyService
    }

    func run(context: PreflightContext) -> [PreflightCheckResult] {
        var results: [PreflightCheckResult] = []

        let proxyValidation = validateProxyURL(context.proxyURLString)
        switch proxyValidation {
        case .success(let valid):
            results.append(.init(
                id: "proxy_url",
                title: String(localized: "Proxy URL"),
                detail: String(localized: "Using") + " " + valid.url.absoluteString,
                status: .pass,
                fixAction: .none
            ))

            if context.useBuiltInProxy {
                if valid.host == "127.0.0.1" || valid.host == "localhost" {
                    results.append(.init(
                        id: "builtin_localhost",
                        title: String(localized: "Built-in Host Restriction"),
                        detail: String(localized: "Built-in mode is safely scoped to localhost."),
                        status: .pass,
                        fixAction: .none
                    ))
                } else {
                    results.append(.init(
                        id: "builtin_localhost",
                        title: String(localized: "Built-in Host Restriction"),
                        detail: String(localized: "Built-in proxy only supports 127.0.0.1 or localhost."),
                        status: .fail,
                        fixAction: .resetProxyURL
                    ))
                }
            }

            if isPortAvailable(valid.port) {
                results.append(.init(
                    id: "port_available",
                    title: String(localized: "Proxy Port Availability"),
                    detail: String(localized: "Port") + " \(valid.port) " + String(localized: "is available."),
                    status: .pass,
                    fixAction: .none
                ))
            } else {
                results.append(.init(
                    id: "port_available",
                    title: String(localized: "Proxy Port Availability"),
                    detail: String(localized: "Port") + " \(valid.port) " + String(localized: "is already in use."),
                    status: .fail,
                    fixAction: .usePort4001
                ))
            }

        case .failure(let issue):
            results.append(.init(
                id: "proxy_url",
                title: String(localized: "Proxy URL"),
                detail: issue.message,
                status: .fail,
                fixAction: .resetProxyURL
            ))
        }

        if validatedUpstreamBaseURL(context.upstreamAPIBaseURLString) != nil {
            results.append(.init(
                id: "upstream_base",
                title: String(localized: "Upstream API Base URL"),
                detail: String(localized: "Upstream API base URL is valid."),
                status: .pass,
                fixAction: .none
            ))
        } else {
            results.append(.init(
                id: "upstream_base",
                title: String(localized: "Upstream API Base URL"),
                detail: String(localized: "Invalid upstream base URL."),
                status: .fail,
                fixAction: .resetUpstreamURL
            ))
        }

        let masterKeyRequired = !context.useBuiltInProxy || context.requireLocalAuth
        if masterKeyRequired {
            if context.hasMasterKey {
                results.append(.init(
                    id: "master_key",
                    title: String(localized: "Local Proxy Password"),
                    detail: String(localized: "Local Proxy Password is set in Keychain."),
                    status: .pass,
                    fixAction: .none
                ))
            } else {
                results.append(.init(
                    id: "master_key",
                    title: String(localized: "Local Proxy Password"),
                    detail: String(localized: "Missing Local Proxy Password in Keychain."),
                    status: .fail,
                    fixAction: .openMasterKeyEditor
                ))
            }
        } else if context.hasMasterKey {
            results.append(.init(
                id: "master_key",
                title: String(localized: "Local Proxy Password"),
                detail: String(localized: "Optional in built-in mode when local auth is disabled."),
                status: .pass,
                fixAction: .none
            ))
        } else {
            results.append(.init(
                id: "master_key",
                title: String(localized: "Local Proxy Password"),
                detail: String(localized: "Optional in built-in mode when local auth is disabled. No action required."),
                status: .info,
                fixAction: .none
            ))
        }

        if context.hasUpstreamKey {
            results.append(.init(
                id: "upstream_key",
                title: String(localized: "Upstream API Key"),
                detail: String(localized: "Upstream API key is set in Keychain."),
                status: .pass,
                fixAction: .none
            ))
        } else {
            results.append(.init(
                id: "upstream_key",
                title: String(localized: "Upstream API Key"),
                detail: String(localized: "Missing upstream API key in Keychain."),
                status: .fail,
                fixAction: .openUpstreamKeyEditor
            ))
        }

        if context.useBuiltInProxy {
            results.append(.init(
                id: "litellm_scripts",
                title: String(localized: "LiteLLM Scripts"),
                detail: String(localized: "Skipped (built-in mode enabled)."),
                status: .info,
                fixAction: .none
            ))
        } else if context.liteLLMScriptsExist {
            results.append(.init(
                id: "litellm_scripts",
                title: String(localized: "LiteLLM Scripts"),
                detail: String(localized: "Required LiteLLM scripts were found."),
                status: .pass,
                fixAction: .none
            ))
        } else {
            results.append(.init(
                id: "litellm_scripts",
                title: String(localized: "LiteLLM Scripts"),
                detail: String(localized: "LiteLLM scripts are missing. Switch to built-in mode or install scripts."),
                status: .fail,
                fixAction: .switchToBuiltInProxy
            ))
        }

        return results
    }

    func validatedUpstreamBaseURL(_ raw: String) -> URL? {
        guard let normalized = proxyService.normalizedUpstreamAPIBase(from: raw),
              let components = URLComponents(url: normalized, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = components.host,
              !host.isEmpty else {
            return nil
        }
        return normalized
    }

    func validateProxyURL(_ raw: String) -> Result<ProxyURLValidation, AppIssue> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http",
              let host = components.host,
              !host.isEmpty else {
            return .failure(AppIssue(
                code: .invalidProxyURL,
                title: String(localized: "Invalid Proxy URL"),
                message: String(localized: "Proxy URL must use http format, for example http://127.0.0.1:4000."),
                actions: [.resetProxyURL]
            ))
        }

        let port = components.port ?? 4000
        guard (1...65535).contains(port) else {
            return .failure(AppIssue(
                code: .invalidPortRange,
                title: String(localized: "Invalid Port"),
                message: String(localized: "Proxy port must be between 1 and 65535."),
                actions: [.resetProxyURL]
            ))
        }

        guard let url = components.url else {
            return .failure(AppIssue(
                code: .invalidProxyURL,
                title: String(localized: "Invalid Proxy URL"),
                message: String(localized: "Proxy URL could not be parsed."),
                actions: [.resetProxyURL]
            ))
        }

        return .success(ProxyURLValidation(url: url, host: host.lowercased(), port: port))
    }

    func isPortAvailable(_ port: Int) -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return false
        }

        do {
            let listener = try NWListener(using: .tcp, on: endpointPort)
            listener.cancel()
            return true
        } catch {
            return false
        }
    }
}
