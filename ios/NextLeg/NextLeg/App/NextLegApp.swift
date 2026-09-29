import SwiftUI

@main
struct NextLegApp: App {
    init() {
        AreaMonitor.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}
