import CoreLocation
import Observation
import UIKit

/// Poloha z CoreLocation. Systém vrací už vyhodnocenou polohu; surová GNSS data (satelity, SNR) nikdy nedává.
@Observable @MainActor
final class LocationProvider: NSObject, SensorProvider, CLLocationManagerDelegate {
    let id = "location"
    let title = "Poloha (GNSS)"
    let systemImage = "location"
    private(set) var metrics: [Metric] = []

    private let manager = CLLocationManager()
    private var location: CLLocation?
    private var heading: CLHeading?
    private var lastError: String?
    private var timer: Timer?
    private var updating = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    var actions: [MetricAction] {
        switch manager.authorizationStatus {
        case .notDetermined:
            return [MetricAction(id: "ask", title: "Povolit polohu při používání", systemImage: "location",
                                 kind: .button { [weak self] in self?.manager.requestWhenInUseAuthorization() })]
        case .denied, .restricted:
            return [MetricAction(id: "settings", title: "Otevřít Nastavení", systemImage: "gear",
                                 kind: .button {
                                     if let url = URL(string: UIApplication.openSettingsURLString) {
                                         UIApplication.shared.open(url)
                                     }
                                 })]
        default:
            return []
        }
    }

    func start() {
        startUpdatesIfAuthorized()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refresh()
    }

    func stop() {
        if updating {
            manager.stopUpdatingLocation()
            manager.stopUpdatingHeading()
            updating = false
        }
        timer?.invalidate()
        timer = nil
    }

    private func startUpdatesIfAuthorized() {
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways, !updating else { return }
        updating = true
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
    }

    // MARK: - CLLocationManagerDelegate (volá se na hlavním vlákně, kde manager vznikl)

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        MainActor.assumeIsolated {
            self.location = last
            self.lastError = nil
            self.refresh()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        MainActor.assumeIsolated {
            self.heading = newHeading
            self.refresh()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            self.startUpdatesIfAuthorized()
            self.refresh()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let text = error.localizedDescription
        MainActor.assumeIsolated {
            self.lastError = text
            self.refresh()
        }
    }

    // MARK: - Metriky

    private func refresh() {
        var m: [Metric] = []
        let status = manager.authorizationStatus

        m.append(.available("auth", "Oprávnění", authText(status), source: "CLLocationManager.authorizationStatus"))
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            m.append(.available("precision", "Přesnost povolená uživatelem",
                                manager.accuracyAuthorization == .fullAccuracy ? "Přesná" : "Přibližná",
                                source: "CLLocationManager.accuracyAuthorization"))
        }

        if let l = location {
            m.append(.available("coord", "Souřadnice",
                                "\(Fmt.num(l.coordinate.latitude, 6)), \(Fmt.num(l.coordinate.longitude, 6))",
                                source: "CLLocation.coordinate"))
            m.append(.available("hacc", "Horizontální přesnost", Fmt.plusMinus(l.horizontalAccuracy, 0, unit: "m"),
                                source: "CLLocation.horizontalAccuracy"))
            if l.verticalAccuracy >= 0 {
                m.append(.available("alt", "Výška nad mořem", Fmt.num(l.altitude, 1) + " m " + Fmt.plusMinus(l.verticalAccuracy, 0, unit: "m"),
                                    source: "CLLocation.altitude"))
                m.append(.available("ellip", "Výška nad elipsoidem WGS84", Fmt.num(l.ellipsoidalAltitude, 1) + " m",
                                    source: "CLLocation.ellipsoidalAltitude"))
            } else {
                m.append(.derived("alt", "Výška", "neplatná", note: "verticalAccuracy < 0 znamená, že fix nemá výšku"))
            }
            if l.speed >= 0 {
                m.append(.available("speed", "Rychlost", Fmt.num(l.speed * 3.6, 1) + " km/h "
                                        + Fmt.plusMinus(l.speedAccuracy * 3.6, 1, unit: "km/h"),
                                    source: "CLLocation.speed (m/s → km/h)"))
            }
            if l.course >= 0 {
                m.append(.available("course", "Kurz pohybu", Fmt.num(l.course, 0) + "° " + Fmt.plusMinus(l.courseAccuracy, 0, unit: "°"),
                                    source: "CLLocation.course"))
            }
            if let floor = l.floor {
                m.append(.available("floor", "Patro", "\(floor.level)", source: "CLLocation.floor"))
            }
            m.append(.derived("age", "Stáří fixu", Fmt.num(Date().timeIntervalSince(l.timestamp), 0) + " s",
                              note: "Nyní − CLLocation.timestamp"))
            if let src = l.sourceInformation {
                var flags: [String] = []
                if src.isSimulatedBySoftware { flags.append("simulováno softwarem") }
                if src.isProducedByAccessory { flags.append("z externího příslušenství") }
                m.append(.available("src", "Původ fixu", flags.isEmpty ? "Zařízení samo" : flags.joined(separator: ", "),
                                    source: "CLLocation.sourceInformation"))
            }
        } else if status == .authorizedWhenInUse || status == .authorizedAlways {
            m.append(.derived("coord", "Souřadnice", lastError ?? "čeká na první fix…", note: "Zatím nepřišla žádná poloha"))
        } else {
            m.append(.permission("coord", "Souřadnice, výška, rychlost, kurz", permissionReason(status)))
        }

        if CLLocationManager.headingAvailable() {
            if let h = heading {
                var text = Fmt.num(h.magneticHeading, 0) + "° magnetický"
                if h.trueHeading >= 0 { text += " · " + Fmt.num(h.trueHeading, 0) + "° skutečný" }
                text += " " + Fmt.plusMinus(h.headingAccuracy, 0, unit: "°")
                m.append(.available("heading", "Kompas", text, source: "CLHeading"))
            }
        } else {
            m.append(.unsupported("heading", "Kompas", "CLLocationManager.headingAvailable() je false."))
        }

        m += [
            .unavailable("sats", "Počet satelitů a konstelace (GPS, Galileo, BeiDou…)",
                         "CoreLocation vrací už vyhodnocenou polohu, ne surová GNSS data."),
            .unavailable("snr", "Síla signálu satelitů (C/N0), DOP", "Stejný důvod: surová data nejsou veřejná."),
            .unavailable("fix", "Typ fixu (2D/3D, A‑GPS, dual‑band L5)", "Bez API; jedinou nápovědou je horizontalAccuracy."),
            .unavailable("source", "Zdroj polohy (GPS vs. Wi‑Fi vs. BTS)", "Systém zdroj nezveřejňuje."),
        ]

        metrics = m
    }

    private func authText(_ s: CLAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "Nezjištěno"
        case .restricted: return "Omezeno"
        case .denied: return "Odepřeno"
        case .authorizedAlways: return "Vždy"
        case .authorizedWhenInUse: return "Při používání"
        @unknown default: return "Neznámé"
        }
    }

    private func permissionReason(_ s: CLAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "Vyžaduje souhlas s polohou (tlačítko níže)."
        case .denied: return "Souhlas odepřen; změnit lze v Nastavení › Soukromí › Polohové služby."
        case .restricted: return "Omezeno správou zařízení."
        default: return "Čeká na data."
        }
    }
}
