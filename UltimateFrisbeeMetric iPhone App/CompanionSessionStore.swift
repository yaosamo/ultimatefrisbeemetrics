import Foundation
import WatchConnectivity

@MainActor
final class CompanionSessionStore: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var sessions: [TrainingSessionSummary] = []
    @Published private(set) var liveMetrics = LiveMetricsSnapshot.idle

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let defaults: UserDefaults
    private let sessionsStorageKey = "iphone_training_sessions"
    private let liveMetricsStorageKey = "iphone_live_metrics"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()

        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
        load()

        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()

            if !session.applicationContext.isEmpty {
                apply(applicationContext: session.applicationContext)
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            self.apply(applicationContext: applicationContext)
        }
    }

    private func apply(applicationContext: [String: Any]) {
        if let sessionsData = applicationContext[CompanionSyncPayload.sessionsKey] as? Data,
           let decodedSessions = try? decoder.decode([TrainingSessionSummary].self, from: sessionsData) {
            sessions = decodedSessions
        }

        if let metricsData = applicationContext[CompanionSyncPayload.liveMetricsKey] as? Data,
           let decodedMetrics = try? decoder.decode(LiveMetricsSnapshot.self, from: metricsData) {
            liveMetrics = decodedMetrics
        }

        persist()
    }

    private func load() {
        if let sessionsData = defaults.data(forKey: sessionsStorageKey),
           let decodedSessions = try? decoder.decode([TrainingSessionSummary].self, from: sessionsData) {
            sessions = decodedSessions
        }

        if let metricsData = defaults.data(forKey: liveMetricsStorageKey),
           let decodedMetrics = try? decoder.decode(LiveMetricsSnapshot.self, from: metricsData) {
            liveMetrics = decodedMetrics
        }
    }

    private func persist() {
        if let sessionsData = try? encoder.encode(sessions) {
            defaults.set(sessionsData, forKey: sessionsStorageKey)
        }

        if let metricsData = try? encoder.encode(liveMetrics) {
            defaults.set(metricsData, forKey: liveMetricsStorageKey)
        }
    }
}
