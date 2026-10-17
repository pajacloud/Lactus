import AVFAudio
import Foundation
import Observation

/// Zvuková cesta přes AVAudioSession. Aplikace nikdy nenahrává, takže hladina mikrofonu je záměrně v šedé zóně.
@Observable @MainActor
final class AudioProvider: SensorProvider {
    let id = "audio"
    let title = "Zvuk"
    let systemImage = "speaker.wave.2"
    private(set) var metrics: [Metric] = []

    private let session = AVAudioSession.sharedInstance()
    private var volumeObservation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []
    private var activationError: String?

    func start() {
        do {
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            activationError = nil
        } catch {
            activationError = error.localizedDescription
        }
        volumeObservation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        let names: [Notification.Name] = [
            AVAudioSession.routeChangeNotification,
            AVAudioSession.silenceSecondaryAudioHintNotification,
            AVAudioSession.interruptionNotification,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
        refresh()
    }

    func stop() {
        volumeObservation = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func refresh() {
        var m: [Metric] = []

        m.append(.available("volume", "Hlasitost výstupu", Fmt.percent(Double(session.outputVolume) * 100, 0),
                            source: "AVAudioSession.outputVolume"))

        let outputs = session.currentRoute.outputs
        m.append(.available("outputs", "Výstup",
                            outputs.isEmpty ? "žádný" : outputs.map { "\($0.portName) (\(portText($0.portType)))" }.joined(separator: "\n"),
                            source: "AVAudioSession.currentRoute.outputs"))
        let inputs = session.currentRoute.inputs
        if !inputs.isEmpty {
            m.append(.available("inputs", "Aktivní vstup",
                                inputs.map { "\($0.portName) (\(portText($0.portType)))" }.joined(separator: "\n"),
                                source: "AVAudioSession.currentRoute.inputs"))
        }
        if let available = session.availableInputs, !available.isEmpty {
            m.append(.available("availinputs", "Dostupné mikrofony",
                                available.map { "\($0.portName) (\(portText($0.portType)))" }.joined(separator: "\n"),
                                source: "AVAudioSession.availableInputs"))
        }
        m.append(.available("other", "Hraje jiná aplikace", session.isOtherAudioPlaying ? "Ano" : "Ne",
                            source: "AVAudioSession.isOtherAudioPlaying"))
        m.append(.available("sr", "Vzorkovací frekvence", Fmt.num(session.sampleRate, 0) + " Hz",
                            source: "AVAudioSession.sampleRate"))
        m.append(.available("latency", "Latence výstup / vstup",
                            "\(Fmt.num(session.outputLatency * 1000, 1)) ms / \(Fmt.num(session.inputLatency * 1000, 1)) ms",
                            source: "AVAudioSession.outputLatency"))
        m.append(.available("buffer", "I/O buffer", Fmt.num(session.ioBufferDuration * 1000, 1) + " ms",
                            source: "AVAudioSession.ioBufferDuration"))
        m.append(.available("channels", "Kanály výstupu", "\(session.outputNumberOfChannels) (max \(session.maximumOutputNumberOfChannels))",
                            source: "AVAudioSession.outputNumberOfChannels"))
        m.append(.available("micperm", "Oprávnění k mikrofonu", recordPermissionText(AVAudioApplication.shared.recordPermission),
                            source: "AVAudioApplication.recordPermission"))
        if let err = activationError {
            m.append(.derived("err", "Aktivace relace", "selhala", note: err))
        }

        m += [
            .unavailable("miclevel", "Hladina mikrofonu (dB)",
                         "Vyžadovalo by oprávnění a trvalý záznam. Lactus záměrně nenahrává."),
            .unavailable("hpbattery", "Baterie sluchátek", "Bez veřejného API; systém ji ukazuje jen ve widgetu Baterie."),
            .unavailable("spl", "Hlasitost v dB SPL", "Hodnota je jen v Zdraví › Sluch, bez API pro čtení v reálném čase."),
            .unavailable("spktemp", "Teplota reproduktoru", "Bez API."),
        ]

        metrics = m
    }

    private func portText(_ type: AVAudioSession.Port) -> String {
        switch type {
        case .builtInSpeaker: return "vestavěný reproduktor"
        case .builtInReceiver: return "sluchátko telefonu"
        case .builtInMic: return "vestavěný mikrofon"
        case .headphones: return "sluchátka"
        case .headsetMic: return "mikrofon sluchátek"
        case .bluetoothA2DP: return "Bluetooth A2DP"
        case .bluetoothHFP: return "Bluetooth HFP"
        case .bluetoothLE: return "Bluetooth LE"
        case .airPlay: return "AirPlay"
        case .carAudio: return "CarPlay"
        case .usbAudio: return "USB audio"
        case .HDMI: return "HDMI"
        case .lineOut: return "linkový výstup"
        case .lineIn: return "linkový vstup"
        default: return type.rawValue
        }
    }

    private func recordPermissionText(_ p: AVAudioApplication.recordPermission) -> String {
        switch p {
        case .granted: return "Uděleno (nepoužíváme)"
        case .denied: return "Odepřeno"
        case .undetermined: return "Nežádáno"
        @unknown default: return "Neznámé"
        }
    }
}
