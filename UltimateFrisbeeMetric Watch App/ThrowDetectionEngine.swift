import CoreMotion
import Foundation

struct ThrowDetectionSample {
    let timestamp: TimeInterval
    let throwDetected: Bool
    let catchDetected: Bool
    let rotationalSpeed: Double
    let accelerationMagnitude: Double
}

struct ThrowDetectionState {
    var throwsCount = 0
    var catchesCount = 0
    var lastThrowAt: TimeInterval = -.infinity
    var lastCatchAt: TimeInterval = -.infinity
    var awaitingCatchUntil: TimeInterval = -.infinity
}

struct ThrowDetectionEngine {
    private let throwRotationThreshold = 7.8
    private let throwAccelerationThreshold = 1.35
    private let catchAccelerationThreshold = 1.9
    private let throwCooldown: TimeInterval = 0.75
    private let catchCooldown: TimeInterval = 0.45
    private let catchWindow: TimeInterval = 2.2

    private(set) var state = ThrowDetectionState()

    mutating func process(deviceMotion: CMDeviceMotion) -> ThrowDetectionSample {
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

        var throwDetected = false
        var catchDetected = false

        if rotation >= throwRotationThreshold,
           acceleration >= throwAccelerationThreshold,
           timestamp - state.lastThrowAt >= throwCooldown {
            state.throwsCount += 1
            state.lastThrowAt = timestamp
            state.awaitingCatchUntil = timestamp + catchWindow
            throwDetected = true
        }

        if timestamp <= state.awaitingCatchUntil,
           timestamp - state.lastThrowAt > 0.18,
           timestamp - state.lastCatchAt >= catchCooldown,
           acceleration >= catchAccelerationThreshold,
           rotation < throwRotationThreshold {
            state.catchesCount += 1
            state.lastCatchAt = timestamp
            state.awaitingCatchUntil = -.infinity
            catchDetected = true
        }

        if timestamp > state.awaitingCatchUntil {
            state.awaitingCatchUntil = -.infinity
        }

        return ThrowDetectionSample(
            timestamp: timestamp,
            throwDetected: throwDetected,
            catchDetected: catchDetected,
            rotationalSpeed: rotation,
            accelerationMagnitude: acceleration
        )
    }

    private func magnitude(x: Double, y: Double, z: Double) -> Double {
        sqrt((x * x) + (y * y) + (z * z))
    }
}
