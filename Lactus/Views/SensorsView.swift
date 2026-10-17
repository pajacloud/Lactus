import SwiftUI

struct SensorsView: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        NavigationStack {
            List {
                LegendRow()
                ForEach(0..<monitor.providers.count, id: \.self) { index in
                    ProviderSection(provider: monitor.providers[index])
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Lactus")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        monitor.toggle()
                    } label: {
                        Image(systemName: monitor.isRunning ? "pause.fill" : "play.fill")
                    }
                    .accessibilityLabel(monitor.isRunning ? "Pozastavit měření" : "Spustit měření")
                }
            }
        }
    }
}

/// Vysvětlivka původu hodnot. Tři druhy řádků, nic víc.
private struct LegendRow: View {
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                legend(icon: "checkmark.circle", color: .primary, text: "Přečteno přímo z veřejného API iOS (zdroj je uveden drobně pod názvem).")
                legend(icon: "function", color: .secondary, text: "Spočítáno aplikací z dostupných dat; poznámka říká jak.")
                legend(icon: "hand.raised", color: .orange, text: "Vyžaduje souhlas uživatele; bez něj hodnotu neukazujeme.")
                legend(icon: "eye.slash", color: .secondary, text: "Šedá zóna: systém hodnotu neposkytuje. Nic si nevymýšlíme.")
            }
            .font(.caption)
        }
    }

    private func legend(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 16)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

struct ProviderSection: View {
    let provider: any SensorProvider
    @State private var showGray = false

    var body: some View {
        Section {
            ForEach(provider.series) { series in
                if series.samples.count >= 2 {
                    SparklineRow(series: series)
                }
            }
            ForEach(provider.visibleMetrics) { metric in
                MetricRow(metric: metric)
            }
            ForEach(provider.actions) { action in
                ActionRow(action: action)
            }
            if !provider.grayMetrics.isEmpty {
                DisclosureGroup(isExpanded: $showGray) {
                    ForEach(provider.grayMetrics) { metric in
                        GrayMetricRow(metric: metric)
                    }
                } label: {
                    Label("Systém neposkytuje (\(provider.grayMetrics.count))", systemImage: "eye.slash")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Label(provider.title, systemImage: provider.systemImage)
        }
    }
}
