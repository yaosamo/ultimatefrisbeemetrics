import SwiftUI

struct TrainingDashboardView: View {
    @EnvironmentObject private var sessionStore: TrainingSessionStore
    @StateObject private var manager = SensorTrainingManager()

    var body: some View {
        List {
            liveSection
            metricsSection
            historySection
        }
        .navigationTitle("UF Metric")
    }

    private var liveSection: some View {
        Section("Live Session") {
            LabeledContent("Status", value: manager.statusText)
            LabeledContent("Elapsed", value: durationText(manager.elapsedTime))

            if manager.sessionState == .active {
                Button("Finish Session") {
                    if let summary = manager.finish() {
                        sessionStore.save(summary: summary)
                    }
                }
                .tint(.green)

                Button("Cancel") {
                    manager.cancel()
                }
                .tint(.red)
            } else {
                Button("Start Tracking") {
                    manager.start()
                }
                .tint(.orange)
            }
        }
    }

    private var metricsSection: some View {
        Section("Metrics") {
            LabeledContent("Throws", value: "\(manager.throwsCount)")
            LabeledContent("Catches", value: "\(manager.catchesCount)")
            LabeledContent("Catch Rate", value: rateText(manager.catchRate))
            LabeledContent("Rotation", value: String(format: "%.2f", manager.liveRotation))
            LabeledContent("Acceleration", value: String(format: "%.2f", manager.liveAcceleration))
        }
    }

    private var historySection: some View {
        Section("Recent Sessions") {
            if sessionStore.sessions.isEmpty {
                Text("No saved drills yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sessionStore.sessions) { session in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.startedAt, style: .date)
                            .font(.headline)
                        Text(session.startedAt, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(session.throwsCount) throws, \(session.catchesCount) catches")
                            .font(.caption)
                        Text("\(rateText(session.catchRate)) catch rate in \(durationText(session.duration))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration.rounded(.down))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func rateText(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }
}

#Preview {
    TrainingDashboardView()
        .environmentObject(TrainingSessionStore())
}
