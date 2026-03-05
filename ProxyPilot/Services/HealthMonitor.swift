import Foundation

enum RecoveryState: Equatable {
    case idle
    case monitoring
    case recovering(attempt: Int, delaySeconds: Int)
    case recovered
    case degraded(reason: String)
}

@MainActor
final class HealthMonitor: NSObject {
    private var timer: Timer?
    private var wasRunning: Bool = false
    private var isRunningProvider: (() -> Bool)?
    private var onUnexpectedStopHandler: (() -> Void)?

    func start(
        interval: TimeInterval = 1.0,
        isRunning: @escaping () -> Bool,
        onUnexpectedStop: @escaping () -> Void
    ) {
        stop()
        isRunningProvider = isRunning
        onUnexpectedStopHandler = onUnexpectedStop
        wasRunning = isRunning()
        timer = Timer.scheduledTimer(timeInterval: interval, target: self, selector: #selector(handleTimerTick), userInfo: nil, repeats: true)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunningProvider = nil
        onUnexpectedStopHandler = nil
    }

    @objc
    private func handleTimerTick() {
        guard let isRunningProvider else { return }
        let runningNow = isRunningProvider()
        if wasRunning && !runningNow {
            onUnexpectedStopHandler?()
        }
        wasRunning = runningNow
    }

    func attemptRecovery(
        delays: [UInt64] = [0, 3, 8],
        onState: @escaping @MainActor (RecoveryState) -> Void,
        operation: @escaping @MainActor (Int) async -> Bool
    ) async -> Bool {
        onState(.monitoring)
        for (index, delaySeconds) in delays.enumerated() {
            let attempt = index + 1
            onState(.recovering(attempt: attempt, delaySeconds: Int(delaySeconds)))
            if attempt > 1 {
                try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            }
            if await operation(attempt) {
                onState(.recovered)
                return true
            }
        }
        onState(.degraded(reason: "Automatic recovery exhausted all retry attempts."))
        return false
    }
}
