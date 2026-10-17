import Observation
import UIKit

/// Baterie. iOS veřejně dává jen úroveň (1 %), stav nabíjení a režim nízké spotřeby.
/// Vše ostatní (zdraví, cykly, teplota, napětí, proud) je v šedé zóně a říkáme to otevřeně.
@Observable @MainActor
final class BatteryProvider: SensorProvider {
    let id = "battery"
    let title = "Baterie"
    let systemImage = "battery.75percent"
    private(set) var metrics: [Metric] = []
    private(set) var series: [MetricSeries] = []

    private var history: [Sample] = []
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    func start() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        refresh()
        let names: [Notification.Name] = [
            UIDevice.batteryLevelDidChangeNotification,
            UIDevice.batteryStateDidChangeNotification,
            .NSProcessInfoPowerStateDidChange,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        timer?.invalidate()
        timer = nil
        UIDevice.current.isBatteryMonitoringEnabled = false
    }

    private func refresh() {
        let device = UIDevice.current
        let level = device.batteryLevel
        let now = Date()

        if level >= 0 {
            let percent = Double(level) * 100
            if history.last?.value != percent || history.isEmpty {
                history.append(Sample(date: now, value: percent))
            }
            if history.count > 720 { history.removeFirst(history.count - 720) }
        }

        var m: [Metric] = []

        if level >= 0 {
            m.append(.available("level", "Úroveň nabití", Fmt.percent(Double(level) * 100, 0),
                                source: "UIDevice.batteryLevel"))
        } else {
            m.append(.unsupported("level", "Úroveň nabití", "UIDevice.batteryLevel vrací −1 (simulátor nebo sledování vypnuto)."))
        }

        m.append(.available("state", "Stav", stateText(device.batteryState), source: "UIDevice.batteryState"))
        m.append(.available("lpm", "Režim nízké spotřeby",
                            ProcessInfo.processInfo.isLowPowerModeEnabled ? "Zapnuto" : "Vypnuto",
                            source: "ProcessInfo.isLowPowerModeEnabled"))

        if let rate = ratePerHour() {
            m.append(.derived("rate", "Rychlost změny", "\(Fmt.signed(rate, 1)) %/h",
                              note: "Ze změn úrovně během běhu aplikace (poslední 2 h)"))
            if level >= 0, abs(rate) > 0.05 {
                let percent = Double(level) * 100
                let hours = rate < 0 ? percent / -rate : (100 - percent) / rate
                let label = rate < 0 ? "Odhad do vybití" : "Odhad do nabití"
                m.append(.derived("eta", label, Fmt.duration(hours * 3600),
                                  note: "Lineární extrapolace z rychlosti změny; systém žádný odhad nedává"))
            }
        } else {
            m.append(.derived("rate", "Rychlost změny", "—",
                              note: "Čeká na alespoň dvě různé hodnoty úrovně v odstupu ≥ 2 min"))
        }

        m += [
            .unavailable("health", "Zdraví baterie (max. kapacita)",
                         "Bez veřejného API. Apple ji ukazuje jen v Nastavení › Baterie › Stav baterie."),
            .unavailable("cycles", "Počet nabíjecích cyklů",
                         "Bez veřejného API. Hodnota je jen v Nastavení › Obecné › Informace."),
            .unavailable("temp", "Teplota baterie",
                         "iOS dává jen slovní stupeň zahřívání (ProcessInfo.thermalState, viz Systém), ne °C."),
            .unavailable("voltage", "Napětí (V)",
                         "IOKit / IOPMPowerSource je na iOS privátní a App Store ho nepovoluje."),
            .unavailable("current", "Proud (mA)", "Stejný důvod: privátní IOKit."),
            .unavailable("capacity", "Kapacita (mAh)", "Stejný důvod: privátní IOKit."),
            .unavailable("wattage", "Výkon nabíječky (W)",
                         "Systém rozlišuje jen „nabíjí se / nenabíjí“, ne wattáž ani typ nabíječky."),
            .unavailable("limit", "Limit nabíjení (80 % atd.)",
                         "Jen v Nastavení › Baterie; aplikace ho nemůže číst ani měnit."),
            .unavailable("optimized", "Optimalizované nabíjení",
                         "Bez API; viditelné jen v Nastavení."),
        ]

        metrics = m
        series = [MetricSeries(id: "level", name: "Úroveň nabití", unit: "%", samples: history, range: 0...100)]
    }

    private func ratePerHour() -> Double? {
        guard let last = history.last else { return nil }
        let window = history.filter { last.date.timeIntervalSince($0.date) <= 7200 }
        guard let first = window.first, last.date.timeIntervalSince(first.date) >= 120,
              first.value != last.value else { return nil }
        let hours = last.date.timeIntervalSince(first.date) / 3600
        return (last.value - first.value) / hours
    }

    private func stateText(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .unplugged: return "Odpojeno, vybíjí se"
        case .charging: return "Nabíjí se"
        case .full: return "Nabito"
        case .unknown: return "Neznámý"
        @unknown default: return "Neznámý"
        }
    }
}
