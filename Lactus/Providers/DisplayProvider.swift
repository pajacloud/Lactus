import Observation
import QuartzCore
import UIKit

/// Displej a senzor přiblížení. Světelný senzor (lux) iOS neposkytuje, jas čteme jen jako aktuální jas panelu.
@Observable @MainActor
final class DisplayProvider: SensorProvider {
    let id = "display"
    let title = "Displej a přiblížení"
    let systemImage = "sun.max"
    private(set) var metrics: [Metric] = []

    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private let probe = DisplayLinkProbe()

    /// Sledování senzoru přiblížení zhasíná displej, když ho něco zakryje. Proto je vypínatelné.
    var proximityEnabled = false {
        didSet {
            UIDevice.current.isProximityMonitoringEnabled = proximityEnabled
            refresh()
        }
    }

    var actions: [MetricAction] {
        [MetricAction(
            id: "proximity",
            title: "Sledovat senzor přiblížení (zhasíná displej)",
            systemImage: "hand.raised",
            kind: .toggle(isOn: { [weak self] in self?.proximityEnabled ?? false },
                          set: { [weak self] value in self?.proximityEnabled = value })
        )]
    }

    private var screen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen
    }

    func start() {
        probe.start()
        UIDevice.current.isProximityMonitoringEnabled = proximityEnabled
        refresh()
        let names: [Notification.Name] = [
            UIScreen.brightnessDidChangeNotification,
            UIDevice.proximityStateDidChangeNotification,
            UIScreen.capturedDidChangeNotification,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func stop() {
        probe.stop()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        timer?.invalidate()
        timer = nil
        UIDevice.current.isProximityMonitoringEnabled = false
    }

    private func refresh() {
        var m: [Metric] = []

        if let screen {
            m.append(.available("brightness", "Jas displeje", Fmt.percent(Double(screen.brightness) * 100, 0),
                                source: "UIScreen.brightness"))
            let native = screen.nativeBounds
            m.append(.available("px", "Rozlišení panelu", "\(Int(native.width)) × \(Int(native.height)) px",
                                source: "UIScreen.nativeBounds"))
            let pts = screen.bounds
            m.append(.available("pt", "Logické rozlišení", "\(Int(pts.width)) × \(Int(pts.height)) pt @\(Fmt.num(screen.scale, 0))x",
                                source: "UIScreen.bounds / scale"))
            m.append(.available("maxfps", "Max. obnovovací frekvence", "\(screen.maximumFramesPerSecond) Hz",
                                source: "UIScreen.maximumFramesPerSecond"))
            if probe.measuredFPS > 0 {
                m.append(.derived("fps", "Frekvence přidělená aplikaci", Fmt.num(probe.measuredFPS, 0) + " Hz",
                                  note: "Z intervalů CADisplayLink; při nečinnosti ProMotion klesá, není to frekvence panelu"))
            }
            m.append(.available("gamut", "Barevný gamut", gamutText(screen.traitCollection.displayGamut),
                                source: "UITraitCollection.displayGamut"))
            m.append(.available("edr", "HDR headroom (aktuální / možný)",
                                "\(Fmt.num(screen.currentEDRHeadroom, 2))× / \(Fmt.num(screen.potentialEDRHeadroom, 2))×",
                                source: "UIScreen.currentEDRHeadroom"))
            m.append(.available("captured", "Zrcadlení / záznam obrazovky", screen.isCaptured ? "Ano" : "Ne",
                                source: "UIScreen.isCaptured"))
            m.append(.available("dimming", "Softwarové ztmavení", screen.wantsSoftwareDimming ? "Ano" : "Ne",
                                source: "UIScreen.wantsSoftwareDimming"))
        } else {
            m.append(.unavailable("screen", "Údaje o displeji", "Scéna okna ještě není připojena."))
        }

        if proximityEnabled {
            m.append(.available("prox", "Senzor přiblížení", UIDevice.current.proximityState ? "Něco je blízko" : "Volno",
                                source: "UIDevice.proximityState"))
        } else {
            m.append(.permission("prox", "Senzor přiblížení",
                                 "Zapněte přepínačem níže; iOS při zakrytí senzoru zhasne displej."))
        }

        m += [
            .unavailable("lux", "Okolní osvětlení (lux)",
                         "Senzor v telefonu je, ale iOS k němu nemá veřejné API. Čitelný je jen výsledný jas displeje."),
            .unavailable("truetone", "True Tone / Night Shift", "Bez veřejného API, jen v Ovládacím centru."),
            .unavailable("panelhz", "Skutečná frekvence panelu", "Jen odvozeně z CADisplayLink (viz výše)."),
            .unavailable("nits", "Jas v nitech, PWM", "Bez API; UIScreen.brightness je jen 0–100 % bez fyzikální jednotky."),
            .unavailable("paneltemp", "Teplota panelu", "Bez API."),
        ]

        metrics = m
    }

    private func gamutText(_ gamut: UIDisplayGamut) -> String {
        switch gamut {
        case .P3: return "Display P3"
        case .SRGB: return "sRGB"
        case .unspecified: return "Neurčeno"
        @unknown default: return "Neznámý"
        }
    }
}

/// Měří, jak často systém volá CADisplayLink. To je frekvence přidělená aplikaci, ne panelu.
@MainActor
final class DisplayLinkProbe: NSObject {
    private(set) var measuredFPS: Double = 0
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var frames = 0
    private var accumulated: CFTimeInterval = 0

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        lastTimestamp = 0
        frames = 0
        accumulated = 0
        measuredFPS = 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        if lastTimestamp > 0 {
            accumulated += link.timestamp - lastTimestamp
            frames += 1
            if accumulated >= 0.5 {
                measuredFPS = Double(frames) / accumulated
                frames = 0
                accumulated = 0
            }
        }
        lastTimestamp = link.timestamp
    }
}
