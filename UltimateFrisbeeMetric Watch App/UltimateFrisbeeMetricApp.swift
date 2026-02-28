import SwiftUI

@main
struct UltimateFrisbeeMetricApp: App {
    @StateObject private var sessionStore = TrainingSessionStore()

    var body: some Scene {
        WindowGroup {
            TrainingDashboardView()
                .environmentObject(sessionStore)
        }
    }
}
