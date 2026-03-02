import SwiftUI

@main
struct UltimateFrisbeeMetriciOSApp: App {
    @StateObject private var store = CompanionSessionStore()

    var body: some Scene {
        WindowGroup {
            CompanionDashboardView()
                .environmentObject(store)
        }
    }
}
