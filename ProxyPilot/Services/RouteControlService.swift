import Foundation
import ProxyPilotCore

/// Reads and mutates the CLI-owned route that serves RepoGPS.
///
/// ProxyPilot has two independent routes, and conflating them is the bug this
/// type exists to prevent:
///
/// - The **Xcode / Claude Agent route** is GUI-owned. The menu bar selection
///   becomes `preferredAnthropicUpstreamModel` and governs the GUI's own
///   `LocalProxyServer`.
/// - The **RepoGPS route** lives in `~/.config/proxypilot/route.json` and is
///   owned by the CLI. `rgps` runs `proxypilot route ensure`, which starts a
///   CLI daemon on that provider/model and serves the `proxypilot-active`
///   alias from it.
///
/// Because both can serve the same port at different times, and because the
/// shared session store shows CLI-daemon traffic in the GUI, the menu bar can
/// look authoritative over RepoGPS while having no effect on it at all. Giving
/// the GUI a real surface for the CLI route is what closes that gap — without
/// merging the two selections, which must stay independently settable.
///
/// **This shells out rather than writing `route.json`.** `proxypilot route set`
/// takes an exclusive `flock` on `route.lock`, SIGTERMs the running daemon, and
/// respawns it on the new selection. Writing the file from here would make the
/// GUI a second writer of state the CLI already serializes, and would skip the
/// daemon restart that actually puts a new route into effect.
///
/// It deliberately does **not** resolve `proxypilot` from `PATH`. A build older
/// than v1.13.0 has no `route` subcommand, and PATH order is not something the
/// app controls; a stale entry earlier in the path would silently fail.
@MainActor
final class RouteControlService: ObservableObject {
    /// Decoded `proxypilot route status --json` output.
    struct Status: Equatable, Sendable {
        var selected = false
        var applied = false
        var reachable = false
        /// `"none"` when no PID file exists, `"cli"` when a CLI daemon owns it.
        var owner = "none"
        var provider: String?
        var model: String?
        var port = 4000
        /// `stopped` | `mismatched` | `models_ready`
        var verificationState = "stopped"

        /// What to show next to the RepoGPS route. `applied` is the only state
        /// that means the daemon is actually serving the selection on the
        /// wire; `selected` alone just means `route.json` records a preference.
        var summary: String {
            switch (selected, applied, reachable) {
            case (false, _, _): return "No route selected"
            case (true, true, _): return "Serving on port \(port)"
            case (true, false, true): return "Proxy reachable, serving a different route"
            case (true, false, false): return "Selected, not running"
            }
        }

        var isServing: Bool { applied }

        /// A route is recorded but nothing serves it, so the GUI can start
        /// it with `route ensure` rather than a `route set` restart.
        ///
        /// This is the only state the menu bar's "Start RepoGPS Proxy" item
        /// covers. Re-picking the current model there was a no-op (the picker
        /// ignores an unchanged selection, and menu pickers do not reliably
        /// report a click on the checked item), so before this existed the
        /// menu could not start a selected-but-idle route at all.
        var needsStart: Bool { selected && !applied }
    }

    enum Availability: Equatable {
        /// A CLI binary that reports the `route_control` capability.
        case ready(URL)
        /// No candidate binary exists on disk.
        case missing
        /// A binary exists but predates route control.
        case tooOld(URL)

        var binary: URL? {
            switch self {
            case .ready(let url), .tooOld(let url): return url
            case .missing: return nil
            }
        }
    }

    @Published private(set) var status = Status()
    @Published private(set) var availability: Availability = .missing
    @Published private(set) var isApplying = false
    @Published private(set) var lastError: String?

    private let home: URL
    private let applicationBundleURL: URL

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundle: Bundle = .main
    ) {
        self.home = home
        self.applicationBundleURL = bundle.bundleURL
    }

    /// Candidates in resolution order. The shared runtime symlink wins because
    /// `runtime activate` keeps it pointing at the newest compatible build.
    nonisolated static func candidateBinaries(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationBundleURL: URL = Bundle.main.bundleURL
    ) -> [URL] {
        let candidates = [
            home.appendingPathComponent(".proxypilot/bin/proxypilot"),
            applicationBundleURL.appendingPathComponent("Contents/Helpers/proxypilot"),
            URL(fileURLWithPath: "/Applications/ProxyPilot.app/Contents/Helpers/proxypilot")
        ]
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    // MARK: - Pure parsing (unit-tested without a binary present)

    /// Decodes `route status --json`. Returns `nil` for output that is not a
    /// JSON object, so a CLI that printed an error is treated as unavailable
    /// rather than as an empty-but-valid route.
    nonisolated static func parseStatus(_ data: Data) -> Status? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var parsed = Status()
        parsed.selected = object["selected"] as? Bool ?? false
        parsed.applied = object["applied"] as? Bool ?? false
        parsed.reachable = object["reachable"] as? Bool ?? false
        parsed.owner = object["owner"] as? String ?? "none"
        parsed.provider = object["provider"] as? String
        parsed.model = object["model"] as? String
        parsed.port = object["port"] as? Int ?? 4000
        parsed.verificationState = object["verification_state"] as? String ?? "stopped"
        return parsed
    }

    /// True when `capabilities --json` advertises transactional route control.
    nonisolated static func supportsRouteControl(_ data: Data) -> Bool {
        guard let values = try? JSONSerialization.jsonObject(with: data) as? [String: Int] else {
            return false
        }
        return values["route_control", default: 0] >= 1
    }

    // MARK: - Process plumbing

    private nonisolated static func run(_ binary: URL, _ arguments: [String]) -> (Data, Int32)? {
        runCapturingErrors(binary, arguments).map { ($0.output, $0.code) }
    }

    /// Like `run`, but keeps standard error.
    ///
    /// The route mutations need it: `route set` reports its failures (lock
    /// contention, a port held by another listener, a daemon that will not
    /// stop) as ArgumentParser `ValidationError`s, which go to stderr with an
    /// empty stdout. `route ensure` runs `route set` with stderr inherited, so
    /// its failures land there too. Discarding stderr left the GUI with only
    /// the generic fallback message. Both pipes are drained at once so a full
    /// stderr buffer cannot block the child while stdout is being read.
    private nonisolated static func runCapturingErrors(
        _ binary: URL,
        _ arguments: [String]
    ) -> (output: Data, errors: Data, code: Int32)? {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = binary
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        guard (try? process.run()) != nil else { return nil }
        let errorReader = ErrorDrain(errors.fileHandleForReading)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorReader.wait()
        process.waitUntilExit()
        return (data, errorData, process.terminationStatus)
    }

    /// Reads a pipe to EOF on a background queue.
    private final class ErrorDrain: @unchecked Sendable {
        private let done = DispatchSemaphore(value: 0)
        private var data = Data()

        init(_ handle: FileHandle) {
            DispatchQueue.global(qos: .userInitiated).async {
                self.data = handle.readDataToEndOfFile()
                self.done.signal()
            }
        }

        func wait() -> Data {
            done.wait()
            return data
        }
    }

    private nonisolated static func resolveAvailability(
        home: URL,
        applicationBundleURL: URL
    ) -> Availability {
        for candidate in candidateBinaries(
            home: home,
            applicationBundleURL: applicationBundleURL
        ) where FileManager.default.isExecutableFile(atPath: candidate.path) {
            guard let (data, code) = run(candidate, ["capabilities", "--json"]), code == 0 else {
                return .tooOld(candidate)
            }
            return supportsRouteControl(data) ? .ready(candidate) : .tooOld(candidate)
        }
        return .missing
    }

    // MARK: - Commands

    /// Re-resolves the CLI and reloads route state. Cheap enough to call on
    /// appear and after any mutation.
    func refresh() async {
        let home = home
        let applicationBundleURL = applicationBundleURL
        let resolved = await Task.detached(priority: .userInitiated) {
            Self.resolveAvailability(
                home: home,
                applicationBundleURL: applicationBundleURL
            )
        }.value
        availability = resolved

        guard case .ready(let binary) = resolved else {
            status = Status()
            return
        }
        let result = await Task.detached(priority: .userInitiated) {
            Self.run(binary, ["route", "status", "--json"])
        }.value
        if let (data, code) = result, code == 0, let parsed = Self.parseStatus(data) {
            apply(parsed)
            // Only a serving route resolves an earlier failure. Clearing on
            // any successful read erased a mutation's error in the same call
            // that reported it (each mutation refreshes afterwards), and again
            // whenever the menu reopened, so a failed start or switch left no
            // trace. The next mutation clears it when it begins.
            if parsed.isServing { lastError = nil }
        }
    }

    /// Installs a parsed route status.
    ///
    /// `refresh()` is the production caller. It is not private because the
    /// route-aware GUI surfaces cannot otherwise be exercised without a real
    /// CLI binary and a running daemon on the test machine — and those surfaces
    /// exist specifically to stop the GUI from misreporting the route, which is
    /// the thing most worth pinning.
    func apply(_ newStatus: Status) {
        status = newStatus
    }

    /// Applies a new RepoGPS route.
    ///
    /// This restarts the CLI daemon by design — `route set` stops the running
    /// one and respawns it on the new selection, so an in-flight RepoGPS
    /// request does not survive. The control that calls this is labelled to
    /// say so rather than hiding it behind a confirmation sheet.
    func applyRoute(provider: String, model: String, port: Int) async {
        guard case .ready(let binary) = availability else {
            lastError = "ProxyPilot CLI with route support was not found."
            return
        }
        guard !provider.isEmpty, !model.isEmpty else {
            lastError = "Pick a provider and model before applying."
            return
        }

        isApplying = true
        defer { isApplying = false }
        lastError = nil

        let arguments = [
            "route", "set",
            "--provider", provider,
            "--model", model,
            "--port", String(port),
            "--json"
        ]
        let result = await Task.detached(priority: .userInitiated) {
            Self.runCapturingErrors(binary, arguments)
        }.value

        guard let result else {
            lastError = "Could not run \(binary.lastPathComponent)."
            return
        }
        guard result.code == 0 else {
            let message = Self.failureMessage(from: result.output, errors: result.errors)
            await refresh()
            lastError = message
            return
        }
        await refresh()
    }

    /// Starts the already-selected RepoGPS route without changing it.
    ///
    /// Runs `proxypilot route ensure --json` — the same command `rgps` runs at
    /// startup. When the selected port is free, `ensure` re-runs `route set`
    /// on the stored selection; when nothing is selected, or something else
    /// already answers on the port (for example ProxyPilot's own Xcode proxy
    /// on 4000), it only prints status and **still exits 0**. Success is
    /// therefore judged by the refreshed `applied` state, never by the exit
    /// code alone.
    ///
    /// No interruption confirmation belongs in front of this: it only acts
    /// when nothing serves the route, so there is no RepoGPS request to cut off.
    func ensureRoute() async {
        guard case .ready(let binary) = availability else {
            lastError = "ProxyPilot CLI with route support was not found."
            return
        }
        guard status.selected else {
            lastError = "Pick a RepoGPS model before starting the route."
            return
        }

        isApplying = true
        defer { isApplying = false }
        lastError = nil

        let result = await Task.detached(priority: .userInitiated) {
            Self.runCapturingErrors(binary, ["route", "ensure", "--json"])
        }.value

        guard let result else {
            lastError = "Could not run \(binary.lastPathComponent)."
            return
        }
        guard result.code == 0 else {
            let message = Self.failureMessage(from: result.output, errors: result.errors)
            await refresh()
            lastError = message
            return
        }
        await refresh()
        guard !status.isServing else { return }
        if !status.selected {
            lastError = "No RepoGPS route is selected."
        } else if status.reachable {
            lastError = "Port \(status.port) is already served by another proxy, so the RepoGPS route was not started. Stop that proxy first."
        } else {
            lastError = "The RepoGPS route did not start."
        }
    }

    /// Prefers a message on stdout, then the first stderr line with
    /// ArgumentParser's `Error: ` prefix removed (unwrapping a JSON error
    /// envelope when that is what follows), then the generic fallback.
    nonisolated static func failureMessage(from data: Data, errors: Data) -> String {
        let fromOutput = failureMessage(from: data)
        guard fromOutput == genericFailureMessage else { return fromOutput }
        // ArgumentParser writes "Error: <message>" followed by usage lines.
        let firstLine = String(decoding: errors, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard var line = firstLine else { return fromOutput }
        if line.hasPrefix("Error: ") { line.removeFirst("Error: ".count) }
        // A failed daemon start inside `route set` surfaces as the `start`
        // command's whole JSON envelope after the prefix; keep only its message.
        return line.isEmpty ? fromOutput : failureMessage(from: Data(line.utf8))
    }

    nonisolated static let genericFailureMessage = "Route change failed."

    /// `route set` reports contention and credential problems on its JSON
    /// contract; fall back to raw text so a plain CLI error is not swallowed.
    nonisolated static func failureMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message
            }
            if let message = object["message"] as? String { return message }
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? genericFailureMessage : text
    }
}
