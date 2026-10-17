import CoreTelephony
import Darwin
import Foundation
import Network
import NetworkExtension
import Observation

/// Síť: NWPathMonitor, CoreTelephony a getifaddrs. SSID, síla signálu a operátor jsou v šedé zóně.
@Observable @MainActor
final class NetworkProvider: SensorProvider {
    let id = "network"
    let title = "Síť"
    let systemImage = "antenna.radiowaves.left.and.right"
    private(set) var metrics: [Metric] = []

    private var monitor: NWPathMonitor?
    private var path: NWPath?
    private let telephony = CTTelephonyNetworkInfo()
    private let cellularData = CTCellularData()
    private var timer: Timer?
    private var wifiNetwork: NEHotspotNetwork?
    private var wifiChecked = false

    func start() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.path = path
                self?.refresh()
            }
        }
        monitor.start(queue: DispatchQueue(label: "cloud.paja.lactus.network"))
        self.monitor = monitor

        telephony.serviceSubscriberCellularProvidersDidUpdateNotifier = { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refresh()
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        telephony.serviceSubscriberCellularProvidersDidUpdateNotifier = nil
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        var m: [Metric] = []

        if let path {
            m.append(.available("status", "Stav připojení", statusText(path.status), source: "NWPath.status"))
            let used = path.availableInterfaces.filter { path.usesInterfaceType($0.type) }
            let primary = used.first ?? path.availableInterfaces.first
            if let primary {
                m.append(.available("iface", "Primární rozhraní", "\(typeText(primary.type)) (\(primary.name))",
                                    source: "NWPath.availableInterfaces"))
            }
            m.append(.available("all", "Dostupná rozhraní",
                                path.availableInterfaces.map { "\($0.name) · \(typeText($0.type))" }.joined(separator: "\n"),
                                source: "NWPath.availableInterfaces"))
            m.append(.available("expensive", "Drahé připojení (data / hotspot)", path.isExpensive ? "Ano" : "Ne",
                                source: "NWPath.isExpensive"))
            m.append(.available("constrained", "Režim nízkých dat", path.isConstrained ? "Ano" : "Ne",
                                source: "NWPath.isConstrained"))
            var stack: [String] = []
            if path.supportsIPv4 { stack.append("IPv4") }
            if path.supportsIPv6 { stack.append("IPv6") }
            if path.supportsDNS { stack.append("DNS") }
            m.append(.available("stack", "Podporuje", stack.isEmpty ? "nic" : stack.joined(separator: ", "),
                                source: "NWPath.supportsIPv4/IPv6/DNS"))
            if !path.gateways.isEmpty {
                m.append(.available("gw", "Brány", path.gateways.map { "\($0)" }.joined(separator: "\n"),
                                    source: "NWPath.gateways"))
            }
            if path.status != .satisfied {
                m.append(.available("reason", "Důvod nedostupnosti", unsatisfiedText(path.unsatisfiedReason),
                                    source: "NWPath.unsatisfiedReason"))
            }
        } else {
            m.append(.derived("status", "Stav připojení", "čeká na NWPathMonitor…", note: "První aktualizace cesty ještě nepřišla"))
        }

        let addresses = localAddresses()
        if !addresses.isEmpty {
            m.append(.available("ip", "Lokální IP adresy",
                                addresses.map { "\($0.interface): \($0.address)" }.joined(separator: "\n"),
                                source: "getifaddrs"))
        }

        // Mobilní síť
        if let rats = telephony.serviceCurrentRadioAccessTechnology, !rats.isEmpty {
            let text = rats.map { key, value in
                let marker = key == telephony.dataServiceIdentifier ? " (data)" : ""
                return ratText(value) + marker
            }.joined(separator: "\n")
            m.append(.available("rat", "Mobilní technologie", text, source: "CTTelephonyNetworkInfo.serviceCurrentRadioAccessTechnology"))
        } else {
            m.append(.unsupported("rat", "Mobilní technologie", "Žádná aktivní mobilní služba (bez SIM nebo simulátor)."))
        }
        m.append(.available("celldata", "Mobilní data pro tuto aplikaci", cellularStateText(cellularData.restrictedState),
                            source: "CTCellularData.restrictedState"))

        let providers = telephony.serviceSubscriberCellularProviders ?? [:]
        let carrierNames = providers.values.compactMap { $0.carrierName }.filter { $0 != "--" && !$0.isEmpty }
        if carrierNames.isEmpty {
            m.append(.unavailable("carrier", "Operátor", "CTCarrier od iOS 16 vrací jen „--“; název operátora už aplikace nedostanou."))
        } else {
            m.append(.available("carrier", "Operátor", carrierNames.joined(separator: ", "), source: "CTCarrier.carrierName"))
        }

        // Wi‑Fi: bez entitlementu vrací nil, což poctivě ukážeme.
        if !wifiChecked {
            wifiChecked = true
            NEHotspotNetwork.fetchCurrent { [weak self] network in
                Task { @MainActor [weak self] in
                    self?.wifiNetwork = network
                    self?.refresh()
                }
            }
        }
        if let wifi = wifiNetwork {
            m.append(.available("ssid", "Wi‑Fi SSID", wifi.ssid, source: "NEHotspotNetwork.fetchCurrent"))
            m.append(.available("bssid", "Wi‑Fi BSSID", wifi.bssid, source: "NEHotspotNetwork"))
            m.append(.available("rssi", "Síla signálu Wi‑Fi (relativní)", Fmt.percent(wifi.signalStrength * 100, 0),
                                source: "NEHotspotNetwork.signalStrength (0–1, ne dBm)"))
            m.append(.available("secure", "Zabezpečení Wi‑Fi", securityText(wifi.securityType), source: "NEHotspotNetwork.securityType"))
        } else {
            m.append(.unavailable("ssid", "Wi‑Fi SSID / BSSID",
                                  "Vyžaduje entitlement „Access Wi‑Fi Information“ a oprávnění k poloze. Bez něj NEHotspotNetwork vrací nil."))
            m.append(.unavailable("rssi", "Síla signálu Wi‑Fi", "Bez entitlementu nic; i s ním jen relativní 0–1, ne dBm."))
        }

        m += [
            .unavailable("cellsignal", "Síla mobilního signálu (dBm, čárky)", "Bez veřejného API."),
            .unavailable("cellid", "Cell ID, TAC, pásmo LTE/NR", "Bez veřejného API."),
            .unavailable("wifiphy", "Kanál, pásmo, rychlost linky Wi‑Fi", "Bez veřejného API."),
            .unavailable("imei", "IMEI, ICCID, telefonní číslo", "Zablokováno kvůli soukromí."),
            .unavailable("usage", "Spotřeba dat podle aplikací", "Sandbox; aplikace vidí jen vlastní přenosy."),
        ]

        metrics = m
    }

    // MARK: - Pomocné

    private struct Address {
        let interface: String
        let address: String
    }

    private func localAddresses() -> [Address] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var result: [Address] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let addr = ptr.pointee.ifa_addr else { continue }
            let family = Int32(addr.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") || name.hasPrefix("utun") || name.hasPrefix("ipsec") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            guard rc == 0 else { continue }
            let text = CStrings.string(host)
            if family == AF_INET6, text.hasPrefix("fe80") { continue } // link-local šum
            result.append(Address(interface: name, address: text))
        }
        return result.sorted { $0.interface < $1.interface }
    }

    private func statusText(_ s: NWPath.Status) -> String {
        switch s {
        case .satisfied: return "Připojeno"
        case .unsatisfied: return "Bez připojení"
        case .requiresConnection: return "Vyžaduje připojení (např. VPN na vyžádání)"
        @unknown default: return "Neznámý"
        }
    }

    private func typeText(_ t: NWInterface.InterfaceType) -> String {
        switch t {
        case .wifi: return "Wi‑Fi"
        case .cellular: return "Mobilní"
        case .wiredEthernet: return "Ethernet"
        case .loopback: return "Loopback"
        case .other: return "Jiné / VPN"
        @unknown default: return "Neznámé"
        }
    }

    private func unsatisfiedText(_ r: NWPath.UnsatisfiedReason) -> String {
        switch r {
        case .notAvailable: return "Síť není dostupná"
        case .cellularDenied: return "Mobilní data zakázána"
        case .wifiDenied: return "Wi‑Fi zakázána"
        case .localNetworkDenied: return "Lokální síť zakázána"
        case .vpnInactive: return "VPN neaktivní"
        @unknown default: return "Neznámý"
        }
    }

    private func ratText(_ rat: String) -> String {
        switch rat {
        case CTRadioAccessTechnologyNR: return "5G (SA)"
        case CTRadioAccessTechnologyNRNSA: return "5G (NSA)"
        case CTRadioAccessTechnologyLTE: return "LTE (4G)"
        case CTRadioAccessTechnologyWCDMA, CTRadioAccessTechnologyHSDPA, CTRadioAccessTechnologyHSUPA: return "3G (UMTS/HSPA)"
        case CTRadioAccessTechnologyEdge: return "EDGE (2G)"
        case CTRadioAccessTechnologyGPRS: return "GPRS (2G)"
        case CTRadioAccessTechnologyCDMA1x, CTRadioAccessTechnologyCDMAEVDORev0,
             CTRadioAccessTechnologyCDMAEVDORevA, CTRadioAccessTechnologyCDMAEVDORevB, CTRadioAccessTechnologyeHRPD:
            return "CDMA"
        default: return rat
        }
    }

    private func cellularStateText(_ s: CTCellularDataRestrictedState) -> String {
        switch s {
        case .restricted: return "Zakázána"
        case .notRestricted: return "Povolena"
        case .restrictedStateUnknown: return "Neznámo"
        @unknown default: return "Neznámo"
        }
    }

    private func securityText(_ s: NEHotspotNetworkSecurityType) -> String {
        switch s {
        case .open: return "Otevřená"
        case .WEP: return "WEP"
        case .personal: return "WPA/WPA2/WPA3 Personal"
        case .enterprise: return "Enterprise"
        case .unknown: return "Neznámé"
        @unknown default: return "Neznámé"
        }
    }
}
