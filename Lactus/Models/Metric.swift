import Foundation

/// Původ každé hodnoty na obrazovce. Každá položka má přesně jeden z těchto stavů,
/// aby bylo vždy jasné, co je skutečně přečtené ze systému a co ne.
enum MetricStatus: Equatable {
    /// Přečteno přímo z veřejného API iOS.
    case available(String)
    /// Spočítáno aplikací z dostupných dat. `note` říká jak.
    case derived(String, note: String)
    /// Hodnota existuje, ale vyžaduje souhlas uživatele.
    case permissionNeeded(reason: String)
    /// Toto zařízení nebo tato verze iOS hodnotu nemá.
    case unsupported(reason: String)
    /// iOS hodnotu neposkytuje žádným veřejným API.
    case unavailable(reason: String)
}

struct Metric: Identifiable, Equatable {
    let id: String
    let name: String
    let status: MetricStatus
    /// Název API, ze kterého hodnota pochází (drobně pod názvem).
    var source: String? = nil

    /// Položky šedé zóny: systém je neposkytuje nebo zařízení je nemá.
    var isGray: Bool {
        switch status {
        case .unavailable, .unsupported: return true
        default: return false
        }
    }

    var reason: String? {
        switch status {
        case .unavailable(let r), .unsupported(let r), .permissionNeeded(let r): return r
        case .derived(_, let note): return note
        case .available: return nil
        }
    }
}

extension Metric {
    static func available(_ id: String, _ name: String, _ value: String, source: String? = nil) -> Metric {
        Metric(id: id, name: name, status: .available(value), source: source)
    }

    static func derived(_ id: String, _ name: String, _ value: String, note: String) -> Metric {
        Metric(id: id, name: name, status: .derived(value, note: note))
    }

    static func permission(_ id: String, _ name: String, _ reason: String) -> Metric {
        Metric(id: id, name: name, status: .permissionNeeded(reason: reason))
    }

    static func unsupported(_ id: String, _ name: String, _ reason: String) -> Metric {
        Metric(id: id, name: name, status: .unsupported(reason: reason))
    }

    static func unavailable(_ id: String, _ name: String, _ reason: String) -> Metric {
        Metric(id: id, name: name, status: .unavailable(reason: reason))
    }
}

/// Jeden vzorek časové řady (pro malé grafy).
struct Sample: Identifiable, Equatable {
    var id: Date { date }
    let date: Date
    let value: Double
}

struct MetricSeries: Identifiable {
    let id: String
    let name: String
    let unit: String
    let samples: [Sample]
    var range: ClosedRange<Double>? = nil
}

/// Akce v sekci (tlačítko pro oprávnění, přepínač senzoru).
struct MetricAction: Identifiable {
    enum Kind {
        // Closury vznikají v @MainActor poskytovatelích a volá je jen UI na hlavním vlákně.
        case button(() -> Void)
        case toggle(isOn: () -> Bool, set: (Bool) -> Void)
    }

    let id: String
    let title: String
    let systemImage: String
    let kind: Kind
}
