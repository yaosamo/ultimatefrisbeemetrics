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
    @Published private(set) var sampleRecordingLabel: MotionSampleLabel?
    @Published private(set) var sampleFramesCaptured = 0
    @Published private(set) var throwsCount = 0
    @Published private(set) var forehandCount = 0
    @Published private(set) var backhandCount = 0
    @Published private(set) var hammerCount = 0
    @Published private(set) var forehandShortCount = 0
    @Published private(set) var forehandLongCount = 0
    @Published private(set) var backhandShortCount = 0
    @Published private(set) var backhandLongCount = 0
    @Published private(set) var hammerShortCount = 0
    @Published private(set) var hammerLongCount = 0
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var liveRotation = 0.0
    @Published private(set) var liveAcceleration = 0.0
    @Published private(set) var statusText = "Ready to train"

    private let motionManager = CMMotionManager()
    private let queue = OperationQueue()
    private var timer: Timer?
    private var sampleRecordingWorkItem: DispatchWorkItem?
    private var sampleRecordingCompletion: ((LabeledMotionSample) -> Void)?
    private var sampleRecordingStartedAt: Date?
    private var sampleRecordingWatchWristName = ""
    private var sampleFrames: [MotionSampleFrame] = []
    private var detector = ThrowDetectionEngine()
    private var startedAt: Date?
    private var sessionOriginTimestamp: TimeInterval?
    private var watchWrist: ThrowDetectionEngine.WatchWrist = .left
    private let sampleRecordingMaxDuration: TimeInterval = 60.0

    init() {
        queue.name = "UltimateFrisbeeMetric.motion"
        queue.qualityOfService = .userInitiated
    }

    func start(watchWrist: ThrowDetectionEngine.WatchWrist) {
        guard motionManager.isDeviceMotionAvailable else {
            sessionState = .unavailable
            statusText = "Motion data unavailable"
            return
        }
        guard sampleRecordingLabel == nil else {
            statusText = "Finish sample recording first"
            return
        }

        stopLiveUpdates()
        detector = ThrowDetectionEngine()
        throwsCount = 0
        forehandCount = 0
        backhandCount = 0
        hammerCount = 0
        forehandShortCount = 0
        forehandLongCount = 0
        backhandShortCount = 0
        backhandLongCount = 0
        hammerShortCount = 0
        hammerLongCount = 0
        elapsedTime = 0
        liveRotation = 0
        liveAcceleration = 0
        startedAt = Date()
        sessionOriginTimestamp = nil
        self.watchWrist = watchWrist
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
            let sample = self.detector.process(deviceMotion: deviceMotion, watchWrist: self.watchWrist)
            self.logMotionSample(deviceMotion, sample: sample)

            Task { @MainActor in
                self.sessionOriginTimestamp = self.sessionOriginTimestamp ?? sample.timestamp
                self.throwsCount = self.detector.state.throwsCount
                self.forehandCount = self.detector.state.forehandCount
                self.backhandCount = self.detector.state.backhandCount
                self.hammerCount = self.detector.state.hammerCount
                self.forehandShortCount = self.detector.state.forehandShortCount
                self.forehandLongCount = self.detector.state.forehandLongCount
                self.backhandShortCount = self.detector.state.backhandShortCount
                self.backhandLongCount = self.detector.state.backhandLongCount
                self.hammerShortCount = self.detector.state.hammerShortCount
                self.hammerLongCount = self.detector.state.hammerLongCount
                self.liveRotation = sample.rotationalSpeed
                self.liveAcceleration = sample.accelerationMagnitude

                if sample.throwDetected {
                    let throwTitle = sample.throwStyle?.title ?? "Throw"
                    let powerTitle = sample.throwPower?.title ?? ""
                    self.statusText = powerTitle.isEmpty ? "\(throwTitle) detected" : "\(powerTitle) \(throwTitle) detected"
                }
            }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, let startedAt = self.startedAt else { return }
            self.elapsedTime = Date().timeIntervalSince(startedAt)
        }
    }

    func startSampleRecording(
        label: MotionSampleLabel,
        watchWrist: ThrowDetectionEngine.WatchWrist,
        watchWristName: String,
        onComplete: @escaping (LabeledMotionSample) -> Void
    ) {
        guard motionManager.isDeviceMotionAvailable else {
            sessionState = .unavailable
            statusText = "Motion data unavailable"
            return
        }
        guard sessionState != .active else {
            statusText = "Finish live session first"
            return
        }
        guard sampleRecordingLabel == nil else {
            statusText = "Already recording sample"
            return
        }

        stopLiveUpdates()
        resetLiveMetrics()
        self.watchWrist = watchWrist
        sampleFrames = []
        sampleFramesCaptured = 0
        sampleRecordingLabel = label
        sampleRecordingStartedAt = Date()
        sampleRecordingWatchWristName = watchWristName
        sampleRecordingCompletion = onComplete
        statusText = "Recording \(label.title)"

        motionManager.deviceMotionUpdateInterval = 1.0 / 50.0
        motionManager.startDeviceMotionUpdates(to: queue) { [weak self] deviceMotion, error in
            guard let self else { return }

            if let error {
                Task { @MainActor in
                    self.statusText = "Motion error: \(error.localizedDescription)"
                    self.stopLiveUpdates()
                    self.sampleRecordingLabel = nil
                }
                return
            }

            guard let deviceMotion else { return }
            let frame = MotionSampleFrame(deviceMotion: deviceMotion)
            self.sampleFrames.append(frame)

            Task { @MainActor in
                self.sampleFramesCaptured = self.sampleFrames.count
                self.liveRotation = sqrt(
                    (deviceMotion.rotationRate.x * deviceMotion.rotationRate.x) +
                    (deviceMotion.rotationRate.y * deviceMotion.rotationRate.y) +
                    (deviceMotion.rotationRate.z * deviceMotion.rotationRate.z)
                )
                self.liveAcceleration = sqrt(
                    (deviceMotion.userAcceleration.x * deviceMotion.userAcceleration.x) +
                    (deviceMotion.userAcceleration.y * deviceMotion.userAcceleration.y) +
                    (deviceMotion.userAcceleration.z * deviceMotion.userAcceleration.z)
                )
            }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, let startedAt = self.sampleRecordingStartedAt else { return }
            self.elapsedTime = Date().timeIntervalSince(startedAt)
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.finishSampleRecording()
        }
        sampleRecordingWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + sampleRecordingMaxDuration, execute: workItem)
    }

    func stopSampleRecording() {
        guard sampleRecordingLabel != nil else { return }
        finishSampleRecording()
    }

    var liveMetricsSnapshot: LiveMetricsSnapshot {
        LiveMetricsSnapshot(
            sessionState: sessionState.rawValue,
            statusText: statusText,
            elapsedTime: elapsedTime,
            throwsCount: throwsCount,
            forehandCount: forehandCount,
            backhandCount: backhandCount,
            hammerCount: hammerCount,
            forehandShortCount: forehandShortCount,
            forehandLongCount: forehandLongCount,
            backhandShortCount: backhandShortCount,
            backhandLongCount: backhandLongCount,
            hammerShortCount: hammerShortCount,
            hammerLongCount: hammerLongCount,
            liveRotation: liveRotation,
            liveAcceleration: liveAcceleration
        )
    }

    func setStatusText(_ text: String) {
        statusText = text
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
            sessionWrist: watchWrist.title,
            duration: elapsedTime,
            throwsCount: throwsCount,
            forehandCount: forehandCount,
            backhandCount: backhandCount,
            hammerCount: hammerCount,
            forehandShortCount: forehandShortCount,
            forehandLongCount: forehandLongCount,
            backhandShortCount: backhandShortCount,
            backhandLongCount: backhandLongCount,
            hammerShortCount: hammerShortCount,
            hammerLongCount: hammerLongCount
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
        sampleRecordingWorkItem?.cancel()
        sampleRecordingWorkItem = nil
    }

    private func resetLiveMetrics() {
        sessionState = .idle
        detector = ThrowDetectionEngine()
        throwsCount = 0
        forehandCount = 0
        backhandCount = 0
        hammerCount = 0
        forehandShortCount = 0
        forehandLongCount = 0
        backhandShortCount = 0
        backhandLongCount = 0
        hammerShortCount = 0
        hammerLongCount = 0
        elapsedTime = 0
        liveRotation = 0
        liveAcceleration = 0
        sampleFramesCaptured = 0
        sampleFrames = []
        sampleRecordingStartedAt = nil
        sampleRecordingWatchWristName = ""
        sampleRecordingCompletion = nil
        sampleRecordingLabel = nil
        startedAt = nil
        sessionOriginTimestamp = nil
    }

    private func finishSampleRecording() {
        guard let label = sampleRecordingLabel else { return }
        motionManager.stopDeviceMotionUpdates()
        timer?.invalidate()
        timer = nil
        sampleRecordingWorkItem = nil

        let sample = LabeledMotionSample(
            id: UUID(),
            label: label,
            watchWrist: sampleRecordingWatchWristName,
            recordedAt: Date(),
            duration: elapsedTime,
            frames: sampleFrames
        )

        Task { @MainActor in
            self.sampleRecordingCompletion?(sample)
            self.statusText = "Saved \(label.title) sample"
            self.sampleRecordingLabel = nil
            self.sampleFramesCaptured = 0
            self.sampleFrames = []
            self.sampleRecordingStartedAt = nil
            self.sampleRecordingWatchWristName = ""
            self.sampleRecordingCompletion = nil
            self.elapsedTime = 0
            self.liveRotation = 0
            self.liveAcceleration = 0
        }
    }

    private func logMotionSample(_ deviceMotion: CMDeviceMotion, sample: ThrowDetectionSample) {
        let rotation = deviceMotion.rotationRate
        let acceleration = deviceMotion.userAcceleration
        let gravity = deviceMotion.gravity

        print(
            String(
                format: """
                [Motion] t=%.3f rot=(%.3f, %.3f, %.3f) rotMag=%.3f accel=(%.3f, %.3f, %.3f) accelMag=%.3f gravity=(%.3f, %.3f, %.3f) wristSpin=%.3f lateralSweep=%.3f throw=%@
                """,
                sample.timestamp,
                rotation.x,
                rotation.y,
                rotation.z,
                sample.rotationalSpeed,
                acceleration.x,
                acceleration.y,
                acceleration.z,
                sample.accelerationMagnitude,
                gravity.x,
                gravity.y,
                gravity.z,
                sample.wristSpin,
                sample.lateralSweep,
                sample.throwStyle?.title ?? (sample.throwDetected ? "yes" : "no")
            )
        )
    }
}

private extension ThrowDetectionEngine.WatchWrist {
    var title: String {
        switch self {
        case .left:
            return "Left"
        case .right:
            return "Right"
        }
    }
}
