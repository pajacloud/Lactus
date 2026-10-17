import SwiftUI

@main
struct LactusApp: App {
    @State private var monitor = Monitor()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(monitor)
                .onAppear { monitor.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: monitor.start()
            case .background: monitor.stop()
            default: break
            }
        }
    }
}
