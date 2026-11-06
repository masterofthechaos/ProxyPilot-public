import AppKit
import Darwin

/// A process that macOS reports as listening on a TCP port.
struct PortOwner: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// This ProxyPilot process.
        case thisApp
        /// Another ProxyPilot app copy (for example an older backup in /Applications).
        case proxyPilotApp
        /// The `proxypilot` CLI daemon (bundled helper or standalone install).
        case proxyPilotCLI
        /// The ProxyPilot Xcode agent helper.
        case proxyPilotAgent
        case other
    }

    let pid: pid_t
    /// Human-readable name: the app's localized name when it's an app, else the executable name.
    let name: String
    /// The .app bundle path for apps, else the executable path. Nil when macOS doesn't expose it.
    let location: String?
    let kind: Kind
}

/// Identifies which process holds a TCP port, using libproc. Only processes the
/// current user may inspect are visible: sockets owned by root or other users,
/// and sockets with no owner (TIME_WAIT), are not reported.
enum PortOwnerResolver {
    static let proxyPilotBundleIDPrefix = "com.yourname.ProxyPilot"

    static func listeningOwners(port: UInt16, currentPID: pid_t = getpid()) -> [PortOwner] {
        let byteCapacity = proc_listallpids(nil, 0)
        guard byteCapacity > 0 else { return [] }
        // Headroom for processes spawned between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(byteCapacity) + 64)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }

        return pids.prefix(Int(count))
            .filter { $0 > 0 && processListens(pid: $0, port: port) }
            .map { owner(for: $0, currentPID: currentPID) }
    }

    static func processListens(pid: pid_t, port: UInt16) -> Bool {
        let byteCount = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard byteCount > 0 else { return false } // EPERM for other users' processes
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(byteCount) / stride)
        let used = fds.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard used > 0 else { return false }

        let socketInfoSize = Int32(MemoryLayout<socket_fdinfo>.size)
        for fd in fds.prefix(Int(used) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, socketInfoSize) == socketInfoSize,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            // insi_lport holds the port in network byte order in its low 16 bits.
            let localPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
            if localPort == port { return true }
        }
        return false
    }

    static func owner(for pid: pid_t, currentPID: pid_t) -> PortOwner {
        let executablePath = Self.executablePath(for: pid)
        let executableName = executablePath.map { ($0 as NSString).lastPathComponent }
            ?? processName(for: pid)

        // Only treat it as an app when the process is the bundle's main executable;
        // helpers nested elsewhere in a bundle keep their own executable name.
        if let app = NSRunningApplication(processIdentifier: pid),
           app.bundleURL?.pathExtension == "app",
           let appName = app.localizedName, !appName.isEmpty,
           executablePath?.contains(".app/Contents/MacOS/") ?? true {
            return PortOwner(
                pid: pid,
                name: appName,
                location: app.bundleURL?.path ?? executablePath,
                kind: kind(pid: pid, currentPID: currentPID, bundleID: app.bundleIdentifier, executableName: executableName)
            )
        }
        return PortOwner(
            pid: pid,
            name: executableName.isEmpty ? "process \(pid)" : executableName,
            location: executablePath,
            kind: kind(pid: pid, currentPID: currentPID, bundleID: nil, executableName: executableName)
        )
    }

    /// Case-sensitive on purpose: the app executable is `ProxyPilot`, the CLI is `proxypilot`.
    static func kind(pid: pid_t, currentPID: pid_t, bundleID: String?, executableName: String) -> PortOwner.Kind {
        if pid == currentPID { return .thisApp }
        if executableName == "proxypilot" { return .proxyPilotCLI }
        if executableName == "proxypilot-agent" { return .proxyPilotAgent }
        if let bundleID, bundleID.hasPrefix(proxyPilotBundleIDPrefix) { return .proxyPilotApp }
        if executableName == "ProxyPilot" { return .proxyPilotApp }
        return .other
    }

    private static func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4) // PROC_PIDPATHINFO_MAXSIZE
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private static func processName(for pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    // MARK: - Messages

    /// One or two sentences naming what holds `port` and what to do about it.
    static func explanation(port: UInt16, owners: [PortOwner]) -> String {
        // Interpolate numbers as plain strings: String(localized:) would format them
        // with locale grouping ("4,000", "PID 31,732").
        let port = String(port)
        guard let first = owners.first else {
            return String(localized: "macOS didn't reveal which process holds port \(port). It may belong to another user or a system service, or it may have just closed. Press Start to retry, choose another port (for example 4001), or run `sudo lsof -nP -iTCP:\(port) -sTCP:LISTEN` in Terminal to see the owner.")
        }
        if owners.count > 1 {
            let list = owners.prefix(3).map { "\($0.name) (PID \(String($0.pid)))" }.joined(separator: ", ")
            return String(localized: "Port \(port) is in use by \(list). Quit the one you don't need, or choose another port (for example 4001).")
        }
        switch first.kind {
        case .thisApp:
            return String(localized: "Port \(port) is still held by this ProxyPilot app (PID \(String(first.pid))), probably a previous listener that hasn't finished closing. Wait a moment, then press Start again.")
        case .proxyPilotCLI:
            return String(localized: "Port \(port) is in use by the ProxyPilot CLI daemon (PID \(String(first.pid))). Run `proxypilot stop` in Terminal, or choose another port (for example 4001).")
        case .proxyPilotAgent:
            return String(localized: "Port \(port) is in use by the ProxyPilot Xcode agent helper (PID \(String(first.pid))). Quit Xcode's agent session, then press Start again.")
        case .proxyPilotApp:
            let whereText = first.location.map { " at \($0)" } ?? ""
            return String(localized: "Port \(port) is in use by another copy of ProxyPilot (PID \(String(first.pid)))\(whereText). Quit it, then press Start again.")
        case .other:
            let whereText = first.location.map { ", \($0)" } ?? ""
            return String(localized: "Port \(port) is in use by \(first.name) (PID \(String(first.pid))\(whereText)). Quit it, or choose another port (for example 4001).")
        }
    }
}

extension AppIssue {
    /// E005 with the port's owner named when macOS exposes it.
    static func portInUse(port: UInt16?, actions: [Action] = [.setProxyURLTo4001, .runPreflight]) -> AppIssue {
        let message: String
        if let port {
            message = PortOwnerResolver.explanation(
                port: port,
                owners: PortOwnerResolver.listeningOwners(port: port)
            )
        } else {
            message = String(localized: "Another process is using this port. Switch to 4001 or free the current port.")
        }
        return AppIssue(
            code: .portInUse,
            title: String(localized: "Proxy Port Already In Use"),
            message: message,
            actions: actions
        )
    }
}
