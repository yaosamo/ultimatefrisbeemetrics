import CoreMotion
import Foundation

@MainActor
final class SensorTrainingManager: ObservableObject {
    enum SessionState: String {
        case idle
        case active
        case unavailable
    }

    @Published private(set) var sessionState: SessionState = .idle
    @Published private(set) var throwsCount = 0
    @Published private(set) var catchesCount = 0
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var liveRotation = 0.0
    @Published private(set) var liveAcceleration = 0.0
    @Published private(set) var statusText = "Ready to train"

    private let motionManager = CMMotionManager()
    private let queue = OperationQueue()
    private var timer: Timer?
    private var detector = ThrowDetectionEngine()
    private var startedAt: Date?
    private var sessionOriginTimestamp: TimeInterval?

    var catchRate: Double {
        guard throwsCount > 0 else { return 0 }
        return Double(catchesCount) / Double(throwsCount)
    }

    init() {
        queue.name = "UltimateFrisbeeMetric.motion"
        queue.qualityOfService = .userInitiated
    }

    func start() {
        guard motionManager.isDeviceMotionAvailable else {
            sessionState = .unavailable
            statusText = "Motion data unavailable"
            return
        }

        stopLiveUpdates()
        detector = ThrowDetectionEngine()
        throwsCount = 0
        catchesCount = 0
        elapsedTime = 0
        liveRotation = 0
        liveAcceleration = 0
        startedAt = Date()
        sessionOriginTimestamp = nil
        sessionState = .active
        statusText = "Tracking throws"

        motionManager.deviceMotionUpdateInterval = 1.0 / 50.0
        motionManager.startDeviceMotionUpdates(to: queue) { [weak self] deviceMotion, error in
            guard let self else { return }

            if let error {
                Task { @MainActor in
                    self.sessionState = .unavailable
                    self.statusText = "Motion error: \(error.localizedDescription)"
                    self.stopLiveUpdates()
                }
                return
            }

            guard let deviceMotion else { return }
            let sample = self.detector.process(deviceMotion: deviceMotion)

            Task { @MainActor in
                self.sessionOriginTimestamp = self.sessionOriginTimestamp ?? sample.timestamp
                self.throwsCount = self.detector.state.throwsCount
                self.catchesCount = self.detector.state.catchesCount
                self.liveRotation = sample.rotationalSpeed
                self.liveAcceleration = sample.accelerationMagnitude

                if sample.throwDetected {
                    self.statusText = "Throw detected"
                } else if sample.catchDetected {
                    self.statusText = "Catch completed"
                }
            }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, let startedAt = self.startedAt else { return }
            self.elapsedTime = Date().timeIntervalSince(startedAt)
        }
    }

    func finish() -> TrainingSessionSummary? {
        guard sessionState == .active, let startedAt else {
            stopLiveUpdates()
            resetLiveMetrics()
            return nil
        }

        let summary = TrainingSessionSummary(
            id: UUID(),
            startedAt: startedAt,
            duration: elapsedTime,
            throwsCount: throwsCount,
            catchesCount: catchesCount
        )

        stopLiveUpdates()
        resetLiveMetrics()
        statusText = "Session saved"
        return summary
    }

    func cancel() {
        stopLiveUpdates()
        resetLiveMetrics()
        statusText = "Session canceled"
    }

    private func stopLiveUpdates() {
        motionManager.stopDeviceMotionUpdates()
        timer?.invalidate()
        timer = nil
    }

    private func resetLiveMetrics() {
        sessionState = .idle
        detector = ThrowDetectionEngine()
        startedAt = nil
        sessionOriginTimestamp = nil
    }
}
