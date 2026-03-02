import Foundation

struct TrainingSessionSummary: Codable, Identifiable, Equatable {
    let id: UUID
    let startedAt: Date
    let sessionWrist: String
    let duration: TimeInterval
    let throwsCount: Int
    let forehandCount: Int
    let backhandCount: Int
    let hammerCount: Int
    let forehandShortCount: Int
    let forehandLongCount: Int
    let backhandShortCount: Int
    let backhandLongCount: Int
    let hammerShortCount: Int
    let hammerLongCount: Int

    init(
        id: UUID,
        startedAt: Date,
        sessionWrist: String,
        duration: TimeInterval,
        throwsCount: Int,
        forehandCount: Int,
        backhandCount: Int,
        hammerCount: Int,
        forehandShortCount: Int,
        forehandLongCount: Int,
        backhandShortCount: Int,
        backhandLongCount: Int,
        hammerShortCount: Int,
        hammerLongCount: Int
    ) {
        self.id = id
        self.startedAt = startedAt
        self.sessionWrist = sessionWrist
        self.duration = duration
        self.throwsCount = throwsCount
        self.forehandCount = forehandCount
        self.backhandCount = backhandCount
        self.hammerCount = hammerCount
        self.forehandShortCount = forehandShortCount
        self.forehandLongCount = forehandLongCount
        self.backhandShortCount = backhandShortCount
        self.backhandLongCount = backhandLongCount
        self.hammerShortCount = hammerShortCount
        self.hammerLongCount = hammerLongCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        sessionWrist = try container.decodeIfPresent(String.self, forKey: .sessionWrist) ?? "Unknown"
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        throwsCount = try container.decode(Int.self, forKey: .throwsCount)
        forehandCount = try container.decodeIfPresent(Int.self, forKey: .forehandCount) ?? 0
        backhandCount = try container.decodeIfPresent(Int.self, forKey: .backhandCount) ?? 0
        hammerCount = try container.decodeIfPresent(Int.self, forKey: .hammerCount) ?? 0
        forehandShortCount = try container.decodeIfPresent(Int.self, forKey: .forehandShortCount) ?? 0
        forehandLongCount = try container.decodeIfPresent(Int.self, forKey: .forehandLongCount) ?? 0
        backhandShortCount = try container.decodeIfPresent(Int.self, forKey: .backhandShortCount) ?? 0
        backhandLongCount = try container.decodeIfPresent(Int.self, forKey: .backhandLongCount) ?? 0
        hammerShortCount = try container.decodeIfPresent(Int.self, forKey: .hammerShortCount) ?? 0
        hammerLongCount = try container.decodeIfPresent(Int.self, forKey: .hammerLongCount) ?? 0
    }
}

struct LiveMetricsSnapshot: Codable, Equatable {
    let sessionState: String
    let statusText: String
    let elapsedTime: TimeInterval
    let throwsCount: Int
    let forehandCount: Int
    let backhandCount: Int
    let hammerCount: Int
    let forehandShortCount: Int
    let forehandLongCount: Int
    let backhandShortCount: Int
    let backhandLongCount: Int
    let hammerShortCount: Int
    let hammerLongCount: Int
    let liveRotation: Double
    let liveAcceleration: Double

    static let idle = LiveMetricsSnapshot(
        sessionState: "idle",
        statusText: "Ready to train",
        elapsedTime: 0,
        throwsCount: 0,
        forehandCount: 0,
        backhandCount: 0,
        hammerCount: 0,
        forehandShortCount: 0,
        forehandLongCount: 0,
        backhandShortCount: 0,
        backhandLongCount: 0,
        hammerShortCount: 0,
        hammerLongCount: 0,
        liveRotation: 0,
        liveAcceleration: 0
    )
}
