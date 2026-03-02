import SwiftUI

@main
struct UltimateFrisbeeMetricApp: App {
    @StateObject private var companionSync = CompanionSyncManager()
    @StateObject private var sessionStore = TrainingSessionStore()
    @StateObject private var sampleStore = MotionSampleStore()

    var body: some Scene {
        WindowGroup {
            TrainingDashboardView()
                .environmentObject(companionSync)
                .environmentObject(sessionStore)
                .environmentObject(sampleStore)
        }
    }
}
