import SwiftUI

private enum WatchWrist: String, CaseIterable, Identifiable {
    case left
    case right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left:
            return "Left"
        case .right:
            return "Right"
        }
    }
}

struct TrainingDashboardView: View {
    @EnvironmentObject private var companionSync: CompanionSyncManager
    @EnvironmentObject private var sessionStore: TrainingSessionStore
    @EnvironmentObject private var sampleStore: MotionSampleStore
    @AppStorage("watch_wrist") private var watchWrist = WatchWrist.left.rawValue
    @State private var sampleLabel = MotionSampleLabel.forehand
    @StateObject private var manager = SensorTrainingManager()

    var body: some View {
        List {
            liveSection
            metricsSection
            samplingSection
            settingsSection
            historySection
        }
        .navigationTitle("UF Metric")
        .onAppear {
            companionSync.syncSessions(sessionStore.sessions)
            companionSync.syncLiveMetrics(manager.liveMetricsSnapshot)
        }
        .onChange(of: sessionStore.sessions) { sessions in
            companionSync.syncSessions(sessions)
        }
        .onChange(of: manager.liveMetricsSnapshot) { snapshot in
            companionSync.syncLiveMetrics(snapshot)
        }
    }

    private var liveSection: some View {
        Section("Live Session") {
            metricRow("Status", value: manager.statusText)
            metricRow("Elapsed", value: durationText(manager.elapsedTime))

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
                    manager.start(watchWrist: selectedWatchWrist.detectorWrist)
                }
                .tint(.orange)
                .disabled(manager.sampleRecordingLabel != nil)
            }
        }
    }

    private var metricsSection: some View {
        Section("Metrics") {
            metricRow("Throws", value: "\(manager.throwsCount)")
            metricRow("Forehand", value: "\(manager.forehandCount)")
            metricRow("Backhand", value: "\(manager.backhandCount)")
            metricRow("Rotation", value: String(format: "%.2f", manager.liveRotation))
            metricRow("Acceleration", value: String(format: "%.2f", manager.liveAcceleration))
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
                        Text("\(session.throwsCount) throws")
                            .font(.caption)
                        Text("\(session.forehandCount) forehands, \(session.backhandCount) backhands")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(durationText(session.duration))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var settingsSection: some View {
        Section("Settings") {
            Picker("Watch Wrist", selection: $watchWrist) {
                ForEach(WatchWrist.allCases) { wrist in
                    Text(wrist.title).tag(wrist.rawValue)
                }
            }

            metricRow("Selected", value: selectedWristTitle)
        }
    }

    private var samplingSection: some View {
        Section("Sampling") {
            Picker("Label", selection: $sampleLabel) {
                ForEach(MotionSampleLabel.allCases) { label in
                    Text(label.title).tag(label)
                }
            }

            metricRow("Total Saved", value: "\(sampleStore.totalCount)")
            metricRow("Wrist", value: selectedWristTitle)
            metricRow("Saved", value: "\(sampleStore.count(for: sampleLabel))")
            if let latestSample = sampleStore.latest(for: sampleLabel) {
                metricRow("Last", value: durationText(latestSample.duration))
            }

            if let recordingLabel = manager.sampleRecordingLabel {
                metricRow("Recording", value: recordingLabel.title)
                metricRow("Elapsed", value: durationText(manager.elapsedTime))
                metricRow("Frames", value: "\(manager.sampleFramesCaptured)")

                Button("Stop Recording") {
                    manager.stopSampleRecording()
                }
                .tint(.red)
            } else {
                metricRow("Max Length", value: "01:00")

                Button("Start Long Recording") {
                    manager.startSampleRecording(
                        label: sampleLabel,
                        watchWrist: selectedWatchWrist.detectorWrist,
                        watchWristName: selectedWatchWrist.title
                    ) { sample in
                        sampleStore.save(sample: sample)
                    }
                }
                .tint(.blue)
                .disabled(manager.sessionState == .active)

                Button("Delete Last Sample") {
                    sampleStore.deleteLatest(for: sampleLabel)
                }
                .tint(.orange)
                .disabled(sampleStore.count(for: sampleLabel) == 0)

                Button("Delete All \(sampleLabel.title)") {
                    sampleStore.deleteAll(for: sampleLabel)
                }
                .tint(.red)
                .disabled(sampleStore.count(for: sampleLabel) == 0)

                Button("Print All Samples JSON") {
                    let exported = sampleStore.printAllSamplesJSONToConsole()
                    manager.setStatusText(
                        exported ? "Exported JSON to console" : "Export failed"
                    )
                }
                .disabled(sampleStore.totalCount == 0)
            }
        }
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration.rounded(.down))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var selectedWristTitle: String {
        selectedWatchWrist.title
    }

    private var selectedWatchWrist: WatchWrist {
        WatchWrist(rawValue: watchWrist) ?? .left
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
}

private extension WatchWrist {
    var detectorWrist: ThrowDetectionEngine.WatchWrist {
        switch self {
        case .left:
            return .left
        case .right:
            return .right
        }
    }
}

#Preview {
    TrainingDashboardView()
        .environmentObject(CompanionSyncManager())
        .environmentObject(TrainingSessionStore())
        .environmentObject(MotionSampleStore())
}
