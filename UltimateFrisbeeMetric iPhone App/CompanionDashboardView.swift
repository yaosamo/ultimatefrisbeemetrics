import SwiftUI

struct CompanionDashboardView: View {
    @EnvironmentObject private var store: CompanionSessionStore

    var body: some View {
        NavigationStack {
            List {
                liveMetricsSection
                sessionsSection
            }
            .navigationTitle("UF Companion")
        }
    }

    private var liveMetricsSection: some View {
        Section("Live Metrics") {
            metricRow("Status", value: store.liveMetrics.statusText)
            metricRow("State", value: store.liveMetrics.sessionState.capitalized)
            metricRow("Elapsed", value: durationText(store.liveMetrics.elapsedTime))
            metricRow("Throws", value: "\(store.liveMetrics.throwsCount)")
            metricRow("Forehand", value: "\(store.liveMetrics.forehandCount)")
            metricRow("Backhand", value: "\(store.liveMetrics.backhandCount)")
            metricRow("Rotation", value: String(format: "%.2f", store.liveMetrics.liveRotation))
            metricRow("Acceleration", value: String(format: "%.2f", store.liveMetrics.liveAcceleration))
        }
    }

    private var sessionsSection: some View {
        Section("Sessions") {
            if store.sessions.isEmpty {
                Text("No watch sessions synced yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.sessions) { session in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(session.startedAt, style: .date)
                            .font(.headline)
                        Text(session.startedAt, style: .time)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(session.throwsCount) throws")
                        Text("\(session.forehandCount) forehands, \(session.backhandCount) backhands")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(durationText(session.duration))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func metricRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
        }
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration.rounded(.down))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

#Preview {
    CompanionDashboardView()
        .environmentObject(CompanionSessionStore())
}
