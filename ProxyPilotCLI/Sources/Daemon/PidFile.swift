import Foundation

enum PidFile {

    static var pidFilePath: URL {
        let configDir: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] {
            configDir = URL(fileURLWithPath: xdg).appendingPathComponent("proxypilot")
        } else {
            configDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config")
                .appendingPathComponent("proxypilot")
        }
        return configDir.appendingPathComponent("proxypilot.pid")
    }

    static func write(pid: Int32) {
        let path = pidFilePath
        let dir = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "\(pid)\n".write(to: path, atomically: true, encoding: .utf8)
    }

    static func read() -> Int32? {
        guard let contents = try? String(contentsOf: pidFilePath, encoding: .utf8) else {
            return nil
        }
        guard let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        guard isProcessRunning(pid: pid) else {
            // Stale PID file — clean it up
            remove()
            return nil
        }
        return pid
    }

    static func remove() {
        try? FileManager.default.removeItem(at: pidFilePath)
    }

    static func isProcessRunning(pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }
}
