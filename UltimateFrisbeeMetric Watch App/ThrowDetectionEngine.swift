import CoreMotion
import Foundation

enum ThrowStyle: String, Codable {
    case forehand
    case backhand
    case hammer

    var title: String {
        switch self {
        case .forehand:
            return "Forehand"
        case .backhand:
            return "Backhand"
        case .hammer:
            return "Hammer"
        }
    }
}

enum ThrowPower: String, Codable {
    case short
    case long

    var title: String {
        switch self {
        case .short:
            return "Short"
        case .long:
            return "Long"
        }
    }
}

struct ThrowDetectionSample {
    let timestamp: TimeInterval
    let throwDetected: Bool
    let rotationalSpeed: Double
    let accelerationMagnitude: Double
    let throwStyle: ThrowStyle?
    let throwPower: ThrowPower?
    let wristSpin: Double
    let lateralSweep: Double
}

struct ThrowDetectionState {
    var throwsCount = 0
    var forehandCount = 0
    var backhandCount = 0
    var hammerCount = 0
    var forehandShortCount = 0
    var forehandLongCount = 0
    var backhandShortCount = 0
    var backhandLongCount = 0
    var hammerShortCount = 0
    var hammerLongCount = 0
    var lastThrowAt: TimeInterval = -.infinity
}

struct ThrowDetectionEngine {
    private struct MotionFrame {
        let timestamp: TimeInterval
        let rotationMagnitude: Double
        let accelerationMagnitude: Double
        let rotationZ: Double
        let accelerationY: Double
        let gravityY: Double
        let gravityZ: Double
    }

    private struct PendingThrow {
        let peakTimestamp: TimeInterval
    }

    enum WatchWrist {
        case left
        case right
    }

    // Learned from current left-handed sample data:
    // hammer has strongly negative release-window gravityY, forehand has
    // positive lateral sweep plus positive post-release Z spin, and backhand
    // is the remaining class.
    private let hammerGravityYThreshold = 0.10
    private let forehandLateralSweepThreshold = 0.30
    private let forehandPostSpinThreshold = 2.0
    private let forehandLongPostSpinThreshold = 7.0
    private let backhandLongAccelerationThreshold = 7.0
    private let hammerLongGravityZThreshold = -0.35
    private let throwRotationThreshold = 7.8
    private let throwAccelerationThreshold = 1.35
    private let throwCooldown: TimeInterval = 0.75
    private let releaseWindowBefore: TimeInterval = 0.10
    private let releaseWindowAfter: TimeInterval = 0.25
    private let frameRetentionWindow: TimeInterval = 0.50

    private(set) var state = ThrowDetectionState()
    private var recentFrames: [MotionFrame] = []
    private var pendingThrow: PendingThrow?

    mutating func process(deviceMotion: CMDeviceMotion, watchWrist: WatchWrist) -> ThrowDetectionSample {
        let timestamp = deviceMotion.timestamp
        let rotation = magnitude(
            x: deviceMotion.rotationRate.x,
            y: deviceMotion.rotationRate.y,
            z: deviceMotion.rotationRate.z
        )
        let acceleration = magnitude(
            x: deviceMotion.userAcceleration.x,
            y: deviceMotion.userAcceleration.y,
            z: deviceMotion.userAcceleration.z
        )
        let wristSpin = adjustedWristSpin(
            zRotation: deviceMotion.rotationRate.z,
            watchWrist: watchWrist
        )
        let lateralSweep = adjustedLateralSweep(
            yAcceleration: deviceMotion.userAcceleration.y,
            watchWrist: watchWrist
        )

        recentFrames.append(
            MotionFrame(
                timestamp: timestamp,
                rotationMagnitude: rotation,
                accelerationMagnitude: acceleration,
                rotationZ: deviceMotion.rotationRate.z,
                accelerationY: deviceMotion.userAcceleration.y,
                gravityY: deviceMotion.gravity.y,
                gravityZ: deviceMotion.gravity.z
            )
        )
        pruneFrames(keepingFrom: timestamp - frameRetentionWindow)

        var throwDetected = false
        var throwStyle: ThrowStyle?
        var throwPower: ThrowPower?

        if pendingThrow == nil,
           rotation >= throwRotationThreshold,
           acceleration >= throwAccelerationThreshold,
           timestamp - state.lastThrowAt >= throwCooldown {
            pendingThrow = PendingThrow(peakTimestamp: timestamp)
            state.lastThrowAt = timestamp
        }

        if let pendingThrow,
           timestamp - pendingThrow.peakTimestamp >= releaseWindowAfter {
            let releaseFrames = recentFrames.filter {
                $0.timestamp >= pendingThrow.peakTimestamp - releaseWindowBefore &&
                $0.timestamp <= pendingThrow.peakTimestamp + releaseWindowAfter
            }
            let classifiedStyle = classifyThrowStyle(
                from: releaseFrames,
                peakTimestamp: pendingThrow.peakTimestamp,
                watchWrist: watchWrist
            )
            let classifiedPower = classifyThrowPower(
                from: releaseFrames,
                style: classifiedStyle,
                peakTimestamp: pendingThrow.peakTimestamp,
                watchWrist: watchWrist
            )

            state.throwsCount += 1
            switch classifiedStyle {
            case .forehand:
                state.forehandCount += 1
                if classifiedPower == .long {
                    state.forehandLongCount += 1
                } else {
                    state.forehandShortCount += 1
                }
            case .backhand:
                state.backhandCount += 1
                if classifiedPower == .long {
                    state.backhandLongCount += 1
                } else {
                    state.backhandShortCount += 1
                }
            case .hammer:
                state.hammerCount += 1
                if classifiedPower == .long {
                    state.hammerLongCount += 1
                } else {
                    state.hammerShortCount += 1
                }
            }

            throwStyle = classifiedStyle
            throwPower = classifiedPower
            throwDetected = true
            self.pendingThrow = nil
        }

        return ThrowDetectionSample(
            timestamp: timestamp,
            throwDetected: throwDetected,
            rotationalSpeed: rotation,
            accelerationMagnitude: acceleration,
            throwStyle: throwStyle,
            throwPower: throwPower,
            wristSpin: wristSpin,
            lateralSweep: lateralSweep
        )
    }

    private func magnitude(x: Double, y: Double, z: Double) -> Double {
        sqrt((x * x) + (y * y) + (z * z))
    }

    private func adjustedWristSpin(zRotation: Double, watchWrist: WatchWrist) -> Double {
        switch watchWrist {
        case .left:
            return zRotation
        case .right:
            return -zRotation
        }
    }

    private func adjustedLateralSweep(yAcceleration: Double, watchWrist: WatchWrist) -> Double {
        switch watchWrist {
        case .left:
            return yAcceleration
        case .right:
            return -yAcceleration
        }
    }

    private mutating func pruneFrames(keepingFrom minimumTimestamp: TimeInterval) {
        recentFrames.removeAll { $0.timestamp < minimumTimestamp }
    }

    private func classifyThrowStyle(
        from frames: [MotionFrame],
        peakTimestamp: TimeInterval,
        watchWrist: WatchWrist
    ) -> ThrowStyle {
        guard !frames.isEmpty else {
            return .backhand
        }

        let normalizedLateralSweep = frames
            .map { adjustedLateralSweep(yAcceleration: $0.accelerationY, watchWrist: watchWrist) }
            .reduce(0.0, +) / Double(frames.count)
        let meanGravityY = frames
            .map(\.gravityY)
            .reduce(0.0, +) / Double(frames.count)

        let postSpinFrames = frames.filter {
            $0.timestamp >= peakTimestamp + 0.02 && $0.timestamp <= peakTimestamp + 0.20
        }
        let normalizedPostSpin = postSpinFrames
            .map { adjustedWristSpin(zRotation: $0.rotationZ, watchWrist: watchWrist) }
            .reduce(0.0, +) / Double(max(postSpinFrames.count, 1))

        if meanGravityY < hammerGravityYThreshold {
            return .hammer
        }

        if normalizedLateralSweep > forehandLateralSweepThreshold,
           normalizedPostSpin > forehandPostSpinThreshold {
            return .forehand
        }

        return .backhand
    }

    private func classifyThrowPower(
        from frames: [MotionFrame],
        style: ThrowStyle,
        peakTimestamp: TimeInterval,
        watchWrist: WatchWrist
    ) -> ThrowPower {
        guard !frames.isEmpty else {
            return .short
        }

        let peakAccelerationMagnitude = frames.map(\.accelerationMagnitude).max() ?? 0.0
        let meanGravityZ = frames
            .map(\.gravityZ)
            .reduce(0.0, +) / Double(frames.count)
        let postSpinFrames = frames.filter { frame in
            frame.timestamp >= peakTimestamp + 0.02 && frame.timestamp <= peakTimestamp + 0.20
        }
        let normalizedPostSpin = postSpinFrames
            .map { adjustedWristSpin(zRotation: $0.rotationZ, watchWrist: watchWrist) }
            .reduce(0.0, +) / Double(max(postSpinFrames.count, 1))

        switch style {
        case .forehand:
            return normalizedPostSpin >= forehandLongPostSpinThreshold ? .long : .short
        case .backhand:
            return peakAccelerationMagnitude >= backhandLongAccelerationThreshold ? .long : .short
        case .hammer:
            return meanGravityZ >= hammerLongGravityZThreshold ? .long : .short
        }
    }
}
