import Foundation
import HealthKit

@MainActor
final class WorkoutSessionManager: NSObject, ObservableObject, HKWorkoutSessionDelegate {
    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?

    var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func start() async throws {
        guard isAvailable else {
            throw WorkoutSessionError.healthDataUnavailable
        }

        try await requestAuthorization()

        if workoutSession != nil {
            return
        }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .unknown

        let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
        session.delegate = self
        workoutSession = session
        session.startActivity(with: Date())
    }

    func end() {
        workoutSession?.end()
        workoutSession = nil
    }

    private func requestAuthorization() async throws {
        let shareTypes: Set = [HKObjectType.workoutType()]

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.requestAuthorization(toShare: shareTypes, read: []) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: WorkoutSessionError.authorizationDenied)
                }
            }
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        if toState == .ended {
            Task { @MainActor in
                self.workoutSession = nil
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            self.workoutSession = nil
        }
    }
}

enum WorkoutSessionError: LocalizedError {
    case healthDataUnavailable
    case authorizationDenied

    var errorDescription: String? {
        switch self {
        case .healthDataUnavailable:
            return "Health data unavailable"
        case .authorizationDenied:
            return "Health authorization denied"
        }
    }
}
