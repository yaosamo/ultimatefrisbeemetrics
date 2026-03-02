import Foundation

struct TrainingSessionSummary: Codable, Identifiable, Equatable {
    let id: UUID
    let startedAt: Date
    let duration: TimeInterval
    let throwsCount: Int
    let forehandCount: Int
    let backhandCount: Int

    init(
        id: UUID,
        startedAt: Date,
        duration: TimeInterval,
        throwsCount: Int,
        forehandCount: Int,
        backhandCount: Int
    ) {
        self.id = id
        self.startedAt = startedAt
        self.duration = duration
        self.throwsCount = throwsCount
        self.forehandCount = forehandCount
        self.backhandCount = backhandCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        throwsCount = try container.decode(Int.self, forKey: .throwsCount)
        forehandCount = try container.decodeIfPresent(Int.self, forKey: .forehandCount) ?? 0
        backhandCount = try container.decodeIfPresent(Int.self, forKey: .backhandCount) ?? 0
    }
}

struct LiveMetricsSnapshot: Codable, Equatable {
    let sessionState: String
    let statusText: String
    let elapsedTime: TimeInterval
    let throwsCount: Int
    let forehandCount: Int
    let backhandCount: Int
    let liveRotation: Double
    let liveAcceleration: Double

    static let idle = LiveMetricsSnapshot(
        sessionState: "idle",
        statusText: "Ready to train",
        elapsedTime: 0,
        throwsCount: 0,
        forehandCount: 0,
        backhandCount: 0,
        liveRotation: 0,
        liveAcceleration: 0
    )
}
