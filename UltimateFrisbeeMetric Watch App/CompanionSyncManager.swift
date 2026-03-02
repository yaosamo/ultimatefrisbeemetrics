import Foundation
import WatchConnectivity

@MainActor
final class CompanionSyncManager: NSObject, ObservableObject, WCSessionDelegate {
    private let encoder = JSONEncoder()
    private let session: WCSession?
    private var activationState: WCSessionActivationState = .notActivated
    private var pendingContext: [String: Any] = [:]

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
        guard session != nil else { return }
        guard let sessionsData = try? encoder.encode(sessions) else { return }

        var context = currentContext()
        context[CompanionSyncPayload.sessionsKey] = sessionsData
        update(context: context)
    }

    func syncLiveMetrics(_ metrics: LiveMetricsSnapshot) {
        guard session != nil else { return }
        guard let metricsData = try? encoder.encode(metrics) else { return }

        var context = currentContext()
        context[CompanionSyncPayload.liveMetricsKey] = metricsData
        update(context: context)
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            self.activationState = activationState
            guard activationState == .activated else { return }

            let contextToSend = self.pendingContext
            self.pendingContext = [:]
            if !contextToSend.isEmpty {
                try? session.updateApplicationContext(contextToSend)
            }
        }
    }

    private func currentContext() -> [String: Any] {
        if activationState == .activated, let session {
            return session.applicationContext
        }
        return pendingContext
    }

    private func update(context: [String: Any]) {
        pendingContext = context
        guard activationState == .activated, let session else { return }
        try? session.updateApplicationContext(context)
    }
}
