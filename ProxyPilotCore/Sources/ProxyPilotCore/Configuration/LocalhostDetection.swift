import Foundation

/// Returns true if the given URL string points to a loopback address.
public func isLocalhostURL(_ urlString: String) -> Bool {
    guard let url = URL(string: urlString), let host = url.host else { return false }
    return isLocalhostHost(host)
}

/// Returns true if the given host string is a loopback host.
public func isLocalhostHost(_ host: String) -> Bool {
    let normalized = host.hasPrefix("[") && host.hasSuffix("]")
        ? String(host.dropFirst().dropLast()) : host
    let lowered = normalized.lowercased()
    // URL(string:).host strips brackets from IPv6, so "[::1]" becomes "::1".
    if lowered == "localhost"
        || lowered == "::1"
        || lowered == "0:0:0:0:0:0:0:1" { return true }

    // A DNS name starting with 127. is not a loopback literal. Require all four
    // decimal octets; reject alternate/octal spellings rather than trusting DNS
    // or platform-specific address normalization at this credential boundary.
    let octets = lowered.split(separator: ".", omittingEmptySubsequences: false)
    return octets.count == 4 && octets.first == "127" && octets.allSatisfy {
        !$0.isEmpty && ($0.count == 1 || !$0.hasPrefix("0"))
            && $0.utf8.allSatisfy { (48...57).contains($0) }
            && UInt8($0) != nil
    }
}
