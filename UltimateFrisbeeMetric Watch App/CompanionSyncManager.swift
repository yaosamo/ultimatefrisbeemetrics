import Foundation
import WatchConnectivity

@MainActor
final class CompanionSyncManager: NSObject, ObservableObject, WCSessionDelegate {
    private let encoder = JSONEncoder()
    private let session: WCSession?

    override init() {
        if WCSession.isSupported() {
            session = WCSession.default
        } else {
            session = nil
        }

        super.init()
        encoder.dateEncodingStrategy = .iso8601
        session?.delegate = self
        session?.activate()
    }

    func syncSessions(_ sessions: [TrainingSessionSummary]) {
        guard let session else { return }
        guard let sessionsData = try? encoder.encode(sessions) else { return }

        var context = session.applicationContext
        context[CompanionSyncPayload.sessionsKey] = sessionsData
        try? session.updateApplicationContext(context)
    }

    func syncLiveMetrics(_ metrics: LiveMetricsSnapshot) {
        guard let session else { return }
        guard let metricsData = try? encoder.encode(metrics) else { return }

        var context = session.applicationContext
        context[CompanionSyncPayload.liveMetricsKey] = metricsData
        try? session.updateApplicationContext(context)
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
    }
}
