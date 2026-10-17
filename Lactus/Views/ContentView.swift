import SwiftUI

struct ContentView: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        TabView {
            SensorsView()
                .tabItem { Label("Senzory", systemImage: "waveform.path.ecg") }
            GrayZoneView()
                .tabItem { Label("Neposkytuje", systemImage: "eye.slash") }
                .badge(monitor.grayCount)
            AboutView()
                .tabItem { Label("O aplikaci", systemImage: "info.circle") }
        }
    }
}

#Preview {
    ContentView()
        .environment(Monitor())
}
