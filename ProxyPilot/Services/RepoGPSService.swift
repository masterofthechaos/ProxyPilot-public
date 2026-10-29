import Foundation
import CryptoKit

@MainActor
final class RepoGPSService: ObservableObject {
    struct DistributionStatus: Decodable, Equatable {
        var installed: Bool
        var ownership: String
        var currentVersion: String?
        var previousVersion: String? = nil
        var executable: String? = nil
        var behaviorPackVersion: String? = nil
        var engineReady: Bool
        // Optional additions preserve status decoding from older RepoGPS payloads.
        var payloadPresent: Bool? = nil
        var integrity: String? = nil
        var repairRequired: Bool? = nil
        var issue: String? = nil
        var pathConfigured: Bool? = nil
        var pathRemediation: String? = nil

        var needsRepair: Bool {
            // External executables remain user-owned, even when unverified.
            guard ownership != "external" else { return false }
            if repairRequired == true { return true }
            guard ownership == "managed" else { return false }
            return !installed || currentVersion == nil || payloadPresent == false || integrity == "missing" || integrity == "unverifiable"
        }

        var pathGuidance: String? {
            guard pathConfigured == false, let pathRemediation,
                  !pathRemediation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return pathRemediation
        }

        var primaryAction: PrimaryAction {
            if ownership == "external" { return .adopt }
            if needsRepair { return .repair }
            return installed ? .maintain : .install
        }

        enum PrimaryAction { case adopt, repair, install, maintain }

        enum CodingKeys: String, CodingKey {
            case installed, ownership, executable
            case currentVersion = "current_version"
            case previousVersion = "previous_version"
            case behaviorPackVersion = "behavior_pack_version"
            case engineReady = "engine_ready"
            case payloadPresent = "payload_present"
            case integrity
            case repairRequired = "repair_required"
            case issue
            case pathConfigured = "path_configured"
            case pathRemediation = "path_remediation"
        }

        static let missing = Self(installed: false, ownership: "missing", currentVersion: nil, previousVersion: nil, executable: nil, behaviorPackVersion: nil, engineReady: false)
    }

    struct SessionStatus: Decodable, Equatable {
        struct Lease: Decodable, Equatable {
            var sessionID: UUID
            var repository: String
            var mode: String
            var activity: String
            var startedAt: Date
            var repoGPSVersion: String
            var behaviorPackVersion: String

            enum CodingKeys: String, CodingKey {
                case repository, mode, activity
                case sessionID = "session_id"
                case startedAt = "started_at"
                case repoGPSVersion = "repogps_version"
                case behaviorPackVersion = "behavior_pack_version"
            }
        }

        var active: Bool
        var lease: Lease?
        var pendingSignals: Int
        var acknowledgedSignals: Int

        enum CodingKeys: String, CodingKey {
            case active, lease
            case pendingSignals = "pending_signals"
            case acknowledgedSignals = "acknowledged_signals"
        }

        static let inactive = Self(active: false, lease: nil, pendingSignals: 0, acknowledgedSignals: 0)
    }

    struct UpdateStatus: Decodable, Equatable {
        var state: String
        var installedVersion: String
        var latestVersion: String
        var ownership: String
        var updateAvailable: Bool
        var compatible: Bool
        var feedURL: URL

        enum CodingKeys: String, CodingKey {
            case state, ownership, compatible
            case installedVersion = "installed_version"
            case latestVersion = "latest_version"
            case updateAvailable = "update_available"
            case feedURL = "feed_url"
        }
    }

    @Published private(set) var distribution = DistributionStatus.missing
    @Published private(set) var session = SessionStatus.inactive
    @Published private(set) var updateStatus: UpdateStatus?
    @Published private(set) var bundledVersion: String?
    @Published private(set) var isWorking = false
    @Published private(set) var isCheckingForUpdates = false
    @Published private(set) var isInstallingProxyPilotCLI = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastReceipt: String?

    typealias CLIActivator = @MainActor () async -> String?

    private let home: URL
    private let bundle: Bundle
    private let cliActivator: CLIActivator
    private var refreshTask: Task<Void, Never>?
    private var lastUpdateCheckAt: Date?
    private var payloadCache: [URL: (fingerprint: String, candidate: PayloadCandidate?)] = [:]

    private static let automaticUpdateCheckInterval: TimeInterval = 6 * 60 * 60

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundle: Bundle = .main,
        cliActivator: CLIActivator? = nil
    ) {
        self.home = home
        self.bundle = bundle
        let bundledCLI = Self.bundledProxyPilotCLI(in: bundle)
        self.cliActivator = cliActivator ?? {
            await Self.activateProxyPilotCLI(at: bundledCLI)
        }
        bundledVersion = payloadManifest()?.payloadVersion
    }

    deinit { refreshTask?.cancel() }

    var isInstalledAndCompatible: Bool {
        distribution.installed && distribution.ownership == "managed" && distribution.currentVersion != nil && !distribution.needsRepair
    }

    var bundledUpdateAvailable: Bool {
        guard distribution.ownership == "managed", let current = distribution.currentVersion, let bundledVersion else { return false }
        return Self.isStableVersion(bundledVersion, newerThan: current)
    }

    var remoteUpdateAvailable: Bool {
        guard distribution.ownership == "managed", let updateStatus else { return false }
        return updateStatus.compatible && updateStatus.updateAvailable
    }

    var updateAvailable: Bool {
        remoteUpdateAvailable || bundledUpdateAvailable
    }

    var executableURL: URL? {
        if let path = distribution.executable { return URL(fileURLWithPath: path) }
        let stable = home.appendingPathComponent(".repogps/bin/rgps")
        return FileManager.default.isExecutableFile(atPath: stable.path) ? stable : nil
    }

    nonisolated static func parseDistributionStatus(_ data: Data) -> DistributionStatus? {
        try? JSONDecoder().decode(DistributionStatus.self, from: data)
    }

    nonisolated static func parseSessionStatus(_ data: Data) -> SessionStatus? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()

            if let value = try? container.decode(String.self) {
                let fractional = ISO8601DateFormatter()
                fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = fractional.date(from: value) {
                    return date
                }

                let standard = ISO8601DateFormatter()
                if let date = standard.date(from: value) {
                    return date
                }
            }

            if let value = try? container.decode(Double.self) {
                // RepoGPS 0.2.0's JSON command reporter uses JSONEncoder's
                // default date representation: seconds since 2001-01-01.
                return Date(timeIntervalSinceReferenceDate: value)
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an ISO-8601 or Foundation reference-date timestamp."
            )
        }
        return try? decoder.decode(SessionStatus.self, from: data)
    }

    nonisolated static func parseUpdateStatus(_ data: Data) -> UpdateStatus? {
        try? JSONDecoder().decode(UpdateStatus.self, from: data)
    }

    nonisolated static func isStableVersion(_ candidate: String, newerThan current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }

    func startMonitoring() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(allowAutomaticUpdate: true)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopMonitoring() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh(allowAutomaticUpdate: Bool = false) async {
        bundledVersion = payloadManifest()?.payloadVersion
        // A broken stable symlink/binary must not hide the managed damage state.
        // The bundled control can report it without executing the damaged payload.
        let candidates = controlCandidates(revalidate: false)
        var observed: DistributionStatus?
        for candidate in candidates {
            if let result = await run(candidate.executable, ["distribution", "status", "--json"]),
               result.code == 0, var decoded = Self.parseDistributionStatus(result.data) {
                if decoded.ownership == "managed", let current = decoded.currentVersion,
                   !candidates.contains(where: { !$0.bundled && $0.version == current }) {
                    // Legacy status producers do not report checksum damage.
                    // Preserve their ownership/version but expose local proof.
                    decoded.integrity = "unverifiable"
                    decoded.repairRequired = true
                    decoded.issue = decoded.issue ?? "The managed RepoGPS payload is missing or could not be verified."
                }
                observed = decoded
                break
            }
        }
        distribution = observed ?? externalStatusIfPresent() ?? damagedManagedStatus() ?? .missing
        if distribution.ownership != "managed" {
            updateStatus = nil
        } else if allowAutomaticUpdate, !isWorking, !distribution.needsRepair {
            await checkForUpdates(force: false, reportFailure: false)
            if remoteUpdateAvailable {
                await installAvailableUpdate(installEngine: false)
                return
            }
            if bundledUpdateAvailable {
                await installBundled(adoptExternal: false, installEngine: false)
                return
            }
        }
        if !distribution.needsRepair, let installed = executableURL,
           let data = await run(installed, ["session", "status", "--json"])?.data,
           let decoded = Self.parseSessionStatus(data) {
            session = decoded
        } else {
            session = .inactive
        }
    }

    func install(adoptExternal: Bool = false, installEngine: Bool = true) async {
        guard await installProxyPilotCLI(reportReceipt: false) else { return }
        if remoteUpdateAvailable, !adoptExternal {
            await installAvailableUpdate(installEngine: installEngine)
        } else {
            await installBundled(adoptExternal: adoptExternal, installEngine: installEngine)
        }
    }

    /// Activates the app-bundled CLI into the shared user runtime used by
    /// RepoGPS. This is both the automatic dependency step for RepoGPS install
    /// and the explicit recovery action shown beside a missing-route warning.
    @discardableResult
    func installProxyPilotCLI(reportReceipt: Bool = true) async -> Bool {
        guard !isInstallingProxyPilotCLI else { return false }
        isInstallingProxyPilotCLI = true
        defer { isInstallingProxyPilotCLI = false }

        if let detail = await cliActivator() {
            lastError = "Could not install ProxyPilot CLI: " + detail
            return false
        }

        lastError = nil
        if reportReceipt {
            lastReceipt = "Installed the bundled ProxyPilot CLI for RepoGPS routing."
        }
        return true
    }

    func repair() async {
        await installBundled(adoptExternal: false, installEngine: true, repair: true)
    }

    func checkForUpdates(force: Bool = true, reportFailure: Bool = true) async {
        guard distribution.ownership == "managed" else {
            updateStatus = nil
            if reportFailure {
                lastError = "Install or adopt RepoGPS before checking for managed updates."
            }
            return
        }
        if !force, let lastUpdateCheckAt,
           Date().timeIntervalSince(lastUpdateCheckAt) < Self.automaticUpdateCheckInterval {
            return
        }
        guard let control = controlCandidates().first else {
            if reportFailure { lastError = "No verified RepoGPS updater is available. Update ProxyPilot to restore its bundled payload." }
            return
        }

        lastUpdateCheckAt = Date()
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }
        guard let result = await run(control.executable, ["update", "--check", "--json"]),
              result.code == 0,
              let decoded = Self.parseUpdateStatus(result.data) else {
            if reportFailure {
                lastError = "Could not check for RepoGPS updates. The current installation was not changed."
            }
            return
        }

        updateStatus = decoded
        if reportFailure {
            lastError = nil
            lastReceipt = decoded.updateAvailable
                ? "RepoGPS \(decoded.latestVersion) is ready to install."
                : "RepoGPS \(decoded.installedVersion) is up to date."
        }
    }

    private func installAvailableUpdate(installEngine: Bool) async {
        guard let control = controlCandidates().first else {
            lastError = "No verified RepoGPS updater is available. Update ProxyPilot to restore its bundled payload."
            return
        }
        isWorking = true
        defer { isWorking = false }
        guard await succeeds(control.executable, ["update", "--json"]) else { return }
        if installEngine, let installed = stableExecutable,
           !(await succeeds(installed, ["engine", "install", "--json"])) { return }
        let version = updateStatus?.latestVersion ?? "the latest version"
        lastReceipt = installEngine
            ? "Updated RepoGPS to \(version) and verified its pinned coding engine."
            : "Updated RepoGPS to \(version)."
        lastError = nil
        updateStatus = nil
        lastUpdateCheckAt = nil
        await refresh()
    }

    private func installBundled(adoptExternal: Bool, installEngine: Bool, repair: Bool = false) async {
        let candidates = controlCandidates()
        guard let selected = Self.preferredPayload(candidates, currentVersion: managedVersion) else {
            if let current = managedVersion {
                lastError = "RepoGPS \(current) needs a verified payload of the same or a newer version. Update ProxyPilot or provide a matching RepoGPS payload; the older bundled fallback was not installed."
            } else {
                lastError = "This ProxyPilot build does not contain a RepoGPS payload."
            }
            return
        }
        // 0.8.1 introduced damage-safe repair; older controls can wedge on the
        // conflicting directory that repair is specifically meant to recover.
        guard !repair || !Self.isStableVersion("0.8.1", newerThan: selected.version) else {
            lastError = "Repair requires RepoGPS 0.8.1 or newer. Update ProxyPilot to obtain a recovery payload."
            return
        }
        isWorking = true
        defer { isWorking = false }
        var args = ["distribution", repair ? "repair" : "install", "--payload", selected.payload.path, "--json"]
        if adoptExternal { args.append("--adopt") }
        guard await succeeds(selected.executable, args) else { return }
        if installEngine, let installed = stableExecutable,
           !(await succeeds(installed, ["engine", "install", "--json"])) { return }
        if repair {
            lastReceipt = "Repaired RepoGPS \(selected.version) from its verified \(selected.bundled ? "bundled" : "installed") payload."
        } else {
            lastReceipt = installEngine ? "Installed RepoGPS and its pinned coding engine." : "Updated RepoGPS from its verified payload."
        }
        lastError = nil
        updateStatus = nil
        lastUpdateCheckAt = nil
        await refresh()
    }

    func rollback() async { await mutate(["distribution", "rollback", "--json"], receipt: "Rolled RepoGPS back to the previous managed payload.") }
    func remove() async { await mutate(["distribution", "remove", "--json"], receipt: "Removed the ProxyPilot-managed RepoGPS installation.") }

    /// Opens a small, one-use `.command` document in Terminal.app. Terminal,
    /// rather than ProxyPilot, owns the resulting process group and TTY; this is
    /// required for OpenCode's interactive input, resize, redraw, and Ctrl-C.
    @discardableResult
    func launch(in repository: URL) async -> Bool {
        guard !distribution.needsRepair, let executableURL else {
            lastError = distribution.needsRepair ? "Repair RepoGPS before opening a terminal session." : "Install RepoGPS before opening a terminal session."
            return false
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repository.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            lastError = "Choose an existing project folder."
            return false
        }

        isWorking = true
        defer { isWorking = false }

        do {
            let launcherDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ProxyPilot-RepoGPS-Launches", isDirectory: true)
            try FileManager.default.createDirectory(
                at: launcherDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcherDirectory.path)

            let launcher = launcherDirectory.appendingPathComponent(UUID().uuidString + ".command")
            let script = Self.terminalLauncherScript(executable: executableURL, repository: repository)
            try Data(script.utf8).write(to: launcher, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)

            guard let result = await run(URL(fileURLWithPath: "/usr/bin/open"), ["-a", "Terminal", launcher.path]), result.code == 0 else {
                try? FileManager.default.removeItem(at: launcher)
                throw RepoGPSLaunchError.terminalDidNotOpen
            }

            lastError = nil
            lastReceipt = "Opened RepoGPS for \(repository.lastPathComponent) in Terminal. Home will show the cockpit when the TUI is ready."
            return true
        } catch {
            lastError = "Could not open RepoGPS in Terminal: \(error.localizedDescription)"
            return false
        }
    }

    func signal(_ type: String) async {
        guard let executableURL else { return }
        guard await succeeds(executableURL, ["session", "signal", "--type", type, "--json"]) else { return }
        lastReceipt = "Sent " + type + " to the active RepoGPS terminal session."
        await refresh()
    }

    private func mutate(_ arguments: [String], receipt: String) async {
        guard let control = controlCandidates().first else {
            lastError = "No verified RepoGPS control is available. Update ProxyPilot or repair RepoGPS first."
            return
        }
        isWorking = true
        defer { isWorking = false }
        guard await succeeds(control.executable, arguments) else { return }
        lastReceipt = receipt
        lastError = nil
        await refresh()
    }

    private var payloadURL: URL? { bundle.resourceURL?.appendingPathComponent("RepoGPSPayload") }
    nonisolated static func bundledProxyPilotCLI(in bundle: Bundle) -> URL {
        bundle.bundleURL.appendingPathComponent("Contents/Helpers/proxypilot")
    }

    private nonisolated static func activateProxyPilotCLI(at binary: URL) async -> String? {
        await Task.detached(priority: .userInitiated) {
            guard FileManager.default.isExecutableFile(atPath: binary.path) else {
                return "This app does not contain an executable ProxyPilot CLI helper."
            }

            let process = Process()
            let output = Pipe()
            process.executableURL = binary
            process.arguments = ["runtime", "activate", "--json"]
            process.standardOutput = output
            process.standardError = output

            do {
                try process.run()
            } catch {
                return error.localizedDescription
            }

            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return message.isEmpty ? "The bundled CLI activation command failed." : message
            }
            return nil
        }.value
    }

    private var stableExecutable: URL? {
        let value = home.appendingPathComponent(".repogps/bin/rgps")
        return FileManager.default.isExecutableFile(atPath: value.path) ? value : nil
    }
    private func externalStatusIfPresent() -> DistributionStatus? {
        let external = home.appendingPathComponent(".local/bin/rgps")
        guard FileManager.default.fileExists(atPath: external.path) else { return nil }
        let managed = home.appendingPathComponent(".repogps/bin/rgps")
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: external.path) {
            let destination = URL(fileURLWithPath: target, relativeTo: external.deletingLastPathComponent()).standardizedFileURL
            let versions = home.appendingPathComponent(".repogps/versions").resolvingSymlinksInPath().path + "/"
            if destination == managed.standardizedFileURL || external.resolvingSymlinksInPath().path.hasPrefix(versions) { return nil }
        }
        return .init(installed: true, ownership: "external", currentVersion: nil, previousVersion: nil, executable: external.resolvingSymlinksInPath().path, behaviorPackVersion: nil, engineReady: false)
    }

    struct PayloadCandidate: Equatable, Sendable {
        var payload: URL
        var executable: URL { payload.appendingPathComponent("bin/rgps") }
        var version: String
        var bundled: Bool
    }

    private struct PayloadManifest: Decodable {
        struct File: Decodable { var path: String; var sha256: String; var executable: Bool }
        var schemaVersion: Int
        var payloadVersion: String
        var repoGPSVersion: String
        var files: [File]
        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case payloadVersion = "payload_version"
            case repoGPSVersion = "repogps_version"
            case files
        }
    }

    /// Select the newest matching executable/payload pair. A newer managed
    /// installation is never silently replaced by an app's older fallback.
    nonisolated static func preferredPayload(_ candidates: [PayloadCandidate], currentVersion: String?) -> PayloadCandidate? {
        candidates.filter { candidate in
            currentVersion.map { !isStableVersion($0, newerThan: candidate.version) } ?? true
        }.sorted { lhs, rhs in
            if lhs.version == rhs.version { return !lhs.bundled && rhs.bundled }
            return isStableVersion(lhs.version, newerThan: rhs.version)
        }.first
    }

    nonisolated static func verifiedPayload(at root: URL, bundled: Bool) -> PayloadCandidate? {
        let fm = FileManager.default
        guard let rootValues = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
              let manifestData = try? Data(contentsOf: root.appendingPathComponent("payload.json")),
              let manifest = try? JSONDecoder().decode(PayloadManifest.self, from: manifestData),
              manifest.schemaVersion == 1, validPayloadVersion(manifest.payloadVersion),
              manifest.payloadVersion == manifest.repoGPSVersion,
              !manifest.files.isEmpty else { return nil }
        var seen = Set<String>()
        for file in manifest.files {
            let components = file.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.isEmpty, !file.path.hasPrefix("/"),
                  !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  seen.insert(file.path).inserted else { return nil }
            var url = root
            for component in components {
                url.appendPathComponent(String(component))
                guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
                      values.isSymbolicLink != true else { return nil }
            }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true,
                  let data = try? Data(contentsOf: url),
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == file.sha256.lowercased(),
                  !file.executable || fm.isExecutableFile(atPath: url.path) else { return nil }
        }
        guard manifest.files.contains(where: { $0.path == "bin/rgps" && $0.executable }) else { return nil }
        return PayloadCandidate(payload: root, version: manifest.payloadVersion, bundled: bundled)
    }

    nonisolated private static func validPayloadVersion(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    private var managedVersion: String? {
        if distribution.ownership == "managed", let value = distribution.currentVersion,
           Self.validPayloadVersion(value) { return value }
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".repogps/distribution.json")),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = state["current_version"] as? String, Self.validPayloadVersion(version) else { return nil }
        return version
    }

    private func controlCandidates(revalidate: Bool = true) -> [PayloadCandidate] {
        var candidates: [PayloadCandidate] = []
        if let version = managedVersion,
           let installed = verifiedControl(at: home.appendingPathComponent(".repogps/versions/" + version), bundled: false, revalidate: revalidate) {
            candidates.append(installed)
        }
        if let payloadURL, let bundled = verifiedControl(at: payloadURL, bundled: true, revalidate: revalidate) { candidates.append(bundled) }
        return candidates.sorted { Self.isStableVersion($0.version, newerThan: $1.version) }
    }

    private func verifiedControl(at root: URL, bundled: Bool, revalidate: Bool) -> PayloadCandidate? {
        // Monitoring runs frequently. Re-hash only when the manifest or file
        // metadata changes; every explicit management action revalidates bytes.
        let fingerprint = payloadFingerprint(at: root)
        if !revalidate, let cached = payloadCache[root], cached.fingerprint == fingerprint {
            return cached.candidate
        }
        let candidate = Self.verifiedPayload(at: root, bundled: bundled)
        payloadCache[root] = (fingerprint, candidate)
        return candidate
    }

    private func payloadFingerprint(at root: URL) -> String {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("payload.json")),
              let manifest = try? JSONDecoder().decode(PayloadManifest.self, from: data) else { return "missing" }
        var value = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let paths = [root, root.appendingPathComponent("payload.json")] + manifest.files.map { root.appendingPathComponent($0.path) }
        for path in paths {
            let attributes = (try? FileManager.default.attributesOfItem(atPath: path.path)) ?? [:]
            for key: FileAttributeKey in [.type, .size, .modificationDate, .posixPermissions, .systemFileNumber] {
                value += "|" + String(describing: attributes[key])
            }
        }
        return value
    }

    private func damagedManagedStatus() -> DistributionStatus? {
        let version = managedVersion
        guard version != nil || FileManager.default.fileExists(atPath: home.appendingPathComponent(".repogps/distribution.json").path) else { return nil }
        return .init(installed: false, ownership: "managed", currentVersion: version, engineReady: false,
                     payloadPresent: version.map { FileManager.default.fileExists(atPath: home.appendingPathComponent(".repogps/versions/" + $0).path) } ?? false,
                     integrity: "unverifiable", repairRequired: true,
                     issue: "No verified RepoGPS control is available. Update ProxyPilot to restore its recovery payload.")
    }
    private func payloadManifest() -> PayloadManifest? {
        guard let url = payloadURL?.appendingPathComponent("payload.json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PayloadManifest.self, from: data)
    }

    private func succeeds(_ binary: URL, _ arguments: [String]) async -> Bool {
        guard let result = await run(binary, arguments) else { lastError = "Could not run RepoGPS."; return false }
        guard result.code == 0 else {
            lastError = result.message.isEmpty ? "RepoGPS command failed." : result.message
            return false
        }
        return true
    }

    private struct ProcessResult: Sendable { var data: Data; var code: Int32; var message: String }

    nonisolated static func terminalLauncherScript(executable: URL, repository: URL) -> String {
        let executable = shellQuote(executable.standardizedFileURL.path)
        let repository = shellQuote(repository.standardizedFileURL.path)
        return """
        #!/bin/zsh
        /bin/rm -f -- "$0" || true
        cd -- \(repository)
        exec \(executable) --dir \(repository)
        """ + "\n"
    }

    nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func run(_ binary: URL, _ arguments: [String]) async -> ProcessResult? {
        let commandHome = home
        return await Task.detached(priority: .utility) {
            let process = Process(); let output = Pipe(); let error = Pipe()
            process.executableURL = binary; process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["RGPS_HOME"] = commandHome.path
            process.environment = environment
            process.standardOutput = output; process.standardError = error
            guard (try? process.run()) != nil else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = error.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let message = String(decoding: errorData.isEmpty ? data : errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return ProcessResult(data: data, code: process.terminationStatus, message: message)
        }.value
    }
}

private enum RepoGPSLaunchError: LocalizedError {
    case terminalDidNotOpen

    var errorDescription: String? {
        "Terminal.app did not accept the RepoGPS launcher."
    }
}
