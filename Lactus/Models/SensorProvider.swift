import Foundation
import Observation

/// Jeden zdroj údajů (baterie, pohyb, síť…). Každý poskytovatel vrací plochý seznam metrik;
/// šedou zónu z nich odvodí UI podle `Metric.isGray`.
@MainActor
protocol SensorProvider: AnyObject, Observable {
    var id: String { get }
    var title: String { get }
    var systemImage: String { get }
    var metrics: [Metric] { get }
    var actions: [MetricAction] { get }
    var series: [MetricSeries] { get }
    func start()
    func stop()
}

extension SensorProvider {
    var actions: [MetricAction] { [] }
    var series: [MetricSeries] { [] }
    var visibleMetrics: [Metric] { metrics.filter { !$0.isGray } }
    var grayMetrics: [Metric] { metrics.filter(\.isGray) }
}

/// Drží všechny poskytovatele a řídí jejich životní cyklus podle stavu scény.
@Observable @MainActor
final class Monitor {
    let providers: [any SensorProvider]
    private(set) var isRunning = false

    init() {
        providers = [
            BatteryProvider(),
            SystemProvider(),
            StorageProvider(),
            DisplayProvider(),
            MotionProvider(),
            LocationProvider(),
            NetworkProvider(),
            AudioProvider(),
            HardwareProvider(),
        ]
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        providers.forEach { $0.start() }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        providers.forEach { $0.stop() }
    }

    func toggle() {
        isRunning ? stop() : start()
    }

    var grayCount: Int { providers.reduce(0) { $0 + $1.grayMetrics.count } }
}
