import AVFoundation
import CoreMedia
import Foundation
import LocalAuthentication
import Metal
import Observation
import UIKit

/// Statické údaje o zařízení: identifikátor modelu, SoC/GPU přes Metal, kamery, biometrie.
@Observable @MainActor
final class HardwareProvider: SensorProvider {
    let id = "hardware"
    let title = "Zařízení"
    let systemImage = "iphone.gen3"
    private(set) var metrics: [Metric] = []

    func start() {
        guard metrics.isEmpty else { return }
        refresh()
    }

    func stop() {}

    private func refresh() {
        var m: [Metric] = []
        let device = UIDevice.current

        // Identifikace
        let machine = Sysctl.string("hw.machine") ?? "?"
        let identifier = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machine
        m.append(.available("machine", "Identifikátor modelu", identifier, source: "sysctl hw.machine"))
        if let marketing = Self.marketingNames[identifier] {
            m.append(.derived("marketing", "Název modelu", marketing,
                              note: "Z tabulky uložené v aplikaci, ne ze systému; může být neúplná"))
        } else {
            m.append(.unavailable("marketing", "Název modelu", "iOS marketingový název nedává a identifikátor \(identifier) v tabulce aplikace není."))
        }
        if let board = Sysctl.string("hw.model") {
            m.append(.available("board", "Kód desky", board, source: "sysctl hw.model"))
        }
        if let target = Sysctl.string("hw.target") {
            m.append(.available("target", "Kód SoC/cíl", target, source: "sysctl hw.target"))
        }
        m.append(.available("sysname", "Systém", "\(device.systemName) \(device.systemVersion)", source: "UIDevice.systemVersion"))
        m.append(.available("devname", "Název zařízení", device.name, source: "UIDevice.name"))
        if let vendorID = device.identifierForVendor {
            m.append(.available("idfv", "Identifikátor pro vývojáře (IDFV)", vendorID.uuidString, source: "UIDevice.identifierForVendor"))
        }
        m.append(.available("idiom", "Typ zařízení", idiomText(device.userInterfaceIdiom), source: "UIDevice.userInterfaceIdiom"))
        m.append(.available("mac", "Běží na Macu", ProcessInfo.processInfo.isiOSAppOnMac ? "Ano" : "Ne", source: "ProcessInfo.isiOSAppOnMac"))

        // CPU detaily přes sysctl
        if let arch = Sysctl.integer("hw.cputype"), let sub = Sysctl.integer("hw.cpusubtype") {
            m.append(.available("arch", "Architektura", archText(arch, sub), source: "sysctl hw.cputype"))
        }
        if let l1 = Sysctl.integer("hw.l1dcachesize"), let l2 = Sysctl.integer("hw.l2cachesize") {
            m.append(.available("cache", "Cache L1d / L2", "\(Fmt.bytes(l1, memory: true)) / \(Fmt.bytes(l2, memory: true))",
                                source: "sysctl hw.l1dcachesize"))
        }
        if let page = Sysctl.integer("hw.pagesize") {
            m.append(.available("page", "Velikost stránky paměti", Fmt.bytes(page, memory: true), source: "sysctl hw.pagesize"))
        }

        // GPU přes Metal
        if let gpu = MTLCreateSystemDefaultDevice() {
            m.append(.available("gpu", "GPU", gpu.name, source: "MTLDevice.name"))
            m.append(.available("gpufamily", "Nejvyšší rodina Metal", highestFamily(gpu), source: "MTLDevice.supportsFamily"))
            m.append(.available("unified", "Sdílená paměť CPU/GPU", gpu.hasUnifiedMemory ? "Ano" : "Ne", source: "MTLDevice.hasUnifiedMemory"))
            m.append(.available("rt", "Hardwarový ray tracing", gpu.supportsRaytracing ? "Ano" : "Ne", source: "MTLDevice.supportsRaytracing"))
            m.append(.available("maxbuf", "Max. velikost bufferu", Fmt.bytes(Int64(gpu.maxBufferLength), memory: true), source: "MTLDevice.maxBufferLength"))
            let tg = gpu.maxThreadsPerThreadgroup
            m.append(.available("tg", "Max. vláken ve skupině", "\(tg.width) × \(tg.height) × \(tg.depth)", source: "MTLDevice.maxThreadsPerThreadgroup"))
        } else {
            m.append(.unsupported("gpu", "GPU", "MTLCreateSystemDefaultDevice vrátilo nil."))
        }

        // Biometrie
        let context = LAContext()
        var laError: NSError?
        let canBiometrics = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &laError)
        m.append(.available("bio", "Biometrie", biometryText(context.biometryType) + (canBiometrics ? "" : " (nenastaveno nebo nedostupné)"),
                            source: "LAContext.biometryType"))
        let hasPasscode = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        m.append(.available("passcode", "Kód zámku nastaven", hasPasscode ? "Ano" : "Ne", source: "LAContext.canEvaluatePolicy"))

        // Kamery (jen výčet hardwaru, bez přístupu k obrazu a bez oprávnění)
        m += cameraMetrics()

        m += [
            .unavailable("serial", "Sériové číslo, IMEI, UDID, MAC adresa", "Zablokováno kvůli soukromí (od iOS 7, resp. iOS 11)."),
            .unavailable("ownername", "Vlastní název zařízení", "UIDevice.name od iOS 16 vrací jen „iPhone“, pokud aplikace nemá zvláštní entitlement."),
            .unavailable("baseband", "Firmware modemu (baseband)", "Bez veřejného API."),
            .unavailable("ane", "Neural Engine: jádra, využití", "Bez veřejného API; existence se pozná jen přes Core ML compute units."),
            .unavailable("soc", "Marketingový název čipu (A19 Pro…)", "Systém ho nedává; Metal vrací jen název GPU."),
            .unavailable("color", "Barva a kapacita varianty", "Bez API; úložiště viz sekce Úložiště."),
        ]

        metrics = m
    }

    // MARK: - Kamery

    private func cameraMetrics() -> [Metric] {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera,
            .builtInTrueDepthCamera, .builtInLiDARDepthCamera,
        ]
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
        guard !session.devices.isEmpty else {
            return [.unsupported("cams", "Kamery", "DiscoverySession nevrátila žádné zařízení (simulátor).")]
        }
        return session.devices.enumerated().map { index, cam in
            let dims = cam.formats
                .map { CMVideoFormatDescriptionGetDimensions($0.formatDescription) }
                .max { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }
            let maxFPS = cam.formats
                .flatMap { $0.videoSupportedFrameRateRanges.map(\.maxFrameRate) }
                .max() ?? 0
            let maxISO = cam.formats.map(\.maxISO).max() ?? 0
            var parts: [String] = []
            if let dims {
                let mp = Double(dims.width) * Double(dims.height) / 1_000_000
                parts.append("\(dims.width)×\(dims.height) (\(Fmt.num(mp, 0)) MP)")
            }
            parts.append("zoom až \(Fmt.num(cam.maxAvailableVideoZoomFactor, 1))×")
            parts.append("až \(Fmt.num(maxFPS, 0)) fps")
            if maxISO > 0 { parts.append("ISO do \(Fmt.num(Double(maxISO), 0))") }
            if cam.hasTorch { parts.append("blesk") }
            let position = cam.position == .front ? "přední" : "zadní"
            return .available("cam\(index)", "\(cam.localizedName) (\(position))", parts.joined(separator: " · "),
                              source: "AVCaptureDevice.DiscoverySession")
        }
    }

    // MARK: - Texty

    private func idiomText(_ idiom: UIUserInterfaceIdiom) -> String {
        switch idiom {
        case .phone: return "iPhone"
        case .pad: return "iPad"
        case .mac: return "Mac"
        case .vision: return "Vision"
        default: return "Jiné"
        }
    }

    private func archText(_ type: Int64, _ sub: Int64) -> String {
        // Hodnoty z <mach/machine.h>; makra s přetypováním Swift neimportuje, proto literály.
        let abi64: Int64 = 0x0100_0000      // CPU_ARCH_ABI64
        let cpuTypeARM: Int64 = 12          // CPU_TYPE_ARM
        let subtypeMask: Int64 = 0xFF00_0000 // CPU_SUBTYPE_MASK
        let subtypeARM64E: Int64 = 2        // CPU_SUBTYPE_ARM64E
        let is64 = type & abi64 != 0
        guard type & ~abi64 == cpuTypeARM else { return "cputype \(type)" }
        if is64, sub & ~subtypeMask == subtypeARM64E { return "arm64e" }
        return is64 ? "arm64" : "arm"
    }

    private func highestFamily(_ gpu: MTLDevice) -> String {
        let families: [(MTLGPUFamily, String)] = [
            (.apple9, "Apple 9"), (.apple8, "Apple 8"), (.apple7, "Apple 7"),
            (.apple6, "Apple 6"), (.apple5, "Apple 5"), (.apple4, "Apple 4"),
        ]
        return families.first { gpu.supportsFamily($0.0) }?.1 ?? "Neznámá"
    }

    private func biometryText(_ type: LABiometryType) -> String {
        switch type {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        case .none: return "Žádná"
        @unknown default: return "Neznámá"
        }
    }

    /// Tabulka identifikátorů. Je to jediné místo, kde aplikace něco „ví“ sama; proto je výsledek označen jako odvozený.
    private static let marketingNames: [String: String] = [
        "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,5": "iPhone 16e",
        "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max",
        "iPhone18,3": "iPhone 17", "iPhone18,4": "iPhone Air",
    ]
}
