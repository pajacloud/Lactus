import Charts
import SwiftUI

struct MetricRow: View {
    let metric: Metric

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(metric.name)
                if let source = metric.source {
                    Text(source)
                        .font(.caption2)
                        .monospaced()
                        .foregroundStyle(.tertiary)
                }
                if case .derived(_, let note) = metric.status {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            valueView
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var valueView: some View {
        switch metric.status {
        case .available(let value):
            Text(value)
                .monospacedDigit()
        case .derived(let value, _):
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "function")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        case .permissionNeeded(let reason):
            VStack(alignment: .trailing, spacing: 2) {
                Label("Vyžaduje souhlas", systemImage: "hand.raised")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .unavailable, .unsupported:
            EmptyView()
        }
    }
}

/// Řádek šedé zóny: název, důvod a štítek, zda jde o limit iOS nebo tohoto zařízení.
struct GrayMetricRow: View {
    let metric: Metric

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(metric.name)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(tag)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(.secondary)
            }
            if let reason = metric.reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var tag: String {
        if case .unsupported = metric.status { return "toto zařízení" }
        return "iOS neposkytuje"
    }
}

struct ActionRow: View {
    let action: MetricAction

    var body: some View {
        switch action.kind {
        case .button(let handler):
            Button {
                handler()
            } label: {
                Label(action.title, systemImage: action.systemImage)
            }
        case .toggle(let isOn, let set):
            Toggle(isOn: Binding(get: { isOn() }, set: { set($0) })) {
                Label(action.title, systemImage: action.systemImage)
            }
        }
    }
}

/// Malý graf posledních vzorků. Jen to, co aplikace sama naměřila za běhu.
struct SparklineRow: View {
    let series: MetricSeries

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(series.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let last = series.samples.last {
                    Text(Fmt.num(last.value, 1) + " " + series.unit)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Chart(series.samples) { sample in
                AreaMark(x: .value("Čas", sample.date), y: .value(series.name, sample.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.35), .clear],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Čas", sample.date), y: .value(series.name, sample.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.accentColor)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: yDomain)
            .frame(height: 44)
            .accessibilityLabel("\(series.name), posledních \(series.samples.count) vzorků")
        }
        .padding(.vertical, 2)
    }

    private var yDomain: ClosedRange<Double> {
        if let range = series.range { return range }
        let values = series.samples.map(\.value)
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        let pad = max((hi - lo) * 0.15, 0.01)
        return (lo - pad)...(hi + pad)
    }
}
