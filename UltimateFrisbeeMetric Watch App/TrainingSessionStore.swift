import Foundation

@MainActor
final class TrainingSessionStore: ObservableObject {
    @Published private(set) var sessions: [TrainingSessionSummary] = []

    private let defaults: UserDefaults
    private let storageKey = "training_session_history"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func save(summary: TrainingSessionSummary) {
        sessions.insert(summary, at: 0)
        sessions = Array(sessions.prefix(20))
        persist()
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            sessions = try decoder.decode([TrainingSessionSummary].self, from: data)
        } catch {
            sessions = []
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(sessions) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
