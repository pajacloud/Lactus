import SwiftUI

/// Souhrn všeho, co iOS aplikacím neposkytuje, na jednom místě a s důvody.
struct GrayZoneView: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Tyto údaje telefon buď měří jen pro sebe, nebo je Apple schválně nezveřejňuje. Žádná aplikace z App Storu k nim nemá přístup; pokud je někde vidíte, jsou odhadnuté nebo opsané z Nastavení. Lactus je neukazuje, protože by si je musel vymyslet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(0..<monitor.providers.count, id: \.self) { index in
                    let provider = monitor.providers[index]
                    if !provider.grayMetrics.isEmpty {
                        Section {
                            ForEach(provider.grayMetrics) { metric in
                                GrayMetricRow(metric: metric)
                            }
                        } header: {
                            Label(provider.title, systemImage: provider.systemImage)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Co iOS neposkytuje")
        }
    }
}
