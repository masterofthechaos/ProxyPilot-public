import Foundation

/// Returns true if the given URL string points to a loopback address.
public func isLocalhostURL(_ urlString: String) -> Bool {
    guard let url = URL(string: urlString), let host = url.host else { return false }
    let lowered = host.lowercased()
    // URL(string:).host strips brackets from IPv6, so "[::1]" becomes "::1"
    return lowered == "localhost" || lowered == "127.0.0.1" || lowered == "::1"
}
