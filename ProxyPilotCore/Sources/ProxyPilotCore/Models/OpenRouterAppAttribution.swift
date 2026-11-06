import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// ProxyPilot's app identity for OpenRouter's "App" column and app rankings.
///
/// OpenRouter treats `HTTP-Referer` as the primary app identifier; without it every
/// generation logs as "Unknown". `X-OpenRouter-Title` is the current title header and
/// `X-Title` the legacy one; both are sent, matching the other Slicewrite apps.
/// Only applied to requests whose host is openrouter.ai, so other providers never
/// receive them.
public enum OpenRouterAppAttribution {
    public static let referer = "https://slicewrite.com/proxypilot"
    public static let title = "ProxyPilot"

    public static let headers: [(name: String, value: String)] = [
        ("HTTP-Referer", referer),
        ("X-OpenRouter-Title", title),
        ("X-Title", title),
    ]

    public static func appliesTo(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host == "openrouter.ai" || host.hasSuffix(".openrouter.ai")
    }

    /// Sets the attribution headers on an OpenRouter request, replacing any values a
    /// downstream client forwarded. No-op for every other host.
    public static func apply(to request: inout URLRequest) {
        guard appliesTo(request.url) else { return }
        for header in headers {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
    }
}
