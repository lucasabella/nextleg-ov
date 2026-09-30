import SwiftUI

@main
struct NextLegApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AreaMonitor.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { AreaMonitor.shared.appBecameActive() }
                }
        }
    }
}
