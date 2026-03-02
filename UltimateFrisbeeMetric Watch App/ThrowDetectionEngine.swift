import CoreMotion
import Foundation

enum ThrowStyle: String, Codable {
    case forehand
    case backhand

    var title: String {
        switch self {
        case .forehand:
            return "Forehand"
        case .backhand:
            return "Backhand"
        }
    }
}

struct ThrowDetectionSample {
    let timestamp: TimeInterval
    let throwDetected: Bool
    let rotationalSpeed: Double
    let accelerationMagnitude: Double
    let throwStyle: ThrowStyle?
    let wristSpin: Double
}

struct ThrowDetectionState {
    var throwsCount = 0
    var forehandCount = 0
    var backhandCount = 0
    var lastThrowAt: TimeInterval = -.infinity
}

struct ThrowDetectionEngine {
    enum WatchWrist {
        case left
        case right
    }

    // Learned from current left-wrist sample data:
    // forehand release spin is strongly positive after wrist normalization,
    // while backhand stays near-zero to negative.
    private let forehandSpinThreshold = 5.016
    private let throwRotationThreshold = 7.8
    private let throwAccelerationThreshold = 1.35
    private let throwCooldown: TimeInterval = 0.75

    private(set) var state = ThrowDetectionState()

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

        var throwDetected = false
        var throwStyle: ThrowStyle?

        if rotation >= throwRotationThreshold,
           acceleration >= throwAccelerationThreshold,
           timestamp - state.lastThrowAt >= throwCooldown {
            state.throwsCount += 1
            throwStyle = classifyThrowStyle(from: wristSpin)
            switch throwStyle {
            case .forehand:
                state.forehandCount += 1
            case .backhand:
                state.backhandCount += 1
            case nil:
                break
            }
            state.lastThrowAt = timestamp
            throwDetected = true
        }

        return ThrowDetectionSample(
            timestamp: timestamp,
            throwDetected: throwDetected,
            rotationalSpeed: rotation,
            accelerationMagnitude: acceleration,
            throwStyle: throwStyle,
            wristSpin: wristSpin
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

    private func classifyThrowStyle(from wristSpin: Double) -> ThrowStyle {
        wristSpin > forehandSpinThreshold ? .forehand : .backhand
    }
}
