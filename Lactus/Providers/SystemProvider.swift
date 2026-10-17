import Darwin
import Foundation
import Observation

/// CPU, paměť, teplota a doba běhu. Používá jen veřejné Mach API (host_statistics64,
/// host_processor_info, task_info, thread_info) a ProcessInfo.
@Observable @MainActor
final class SystemProvider: SensorProvider {
    let id = "system"
    let title = "Systém"
    let systemImage = "cpu"
    private(set) var metrics: [Metric] = []
    private(set) var series: [MetricSeries] = []

    private var timer: Timer?
    private var thermalObserver: NSObjectProtocol?
    private var previousTicks: [CPUTicks] = []
    private var cpuReadError: kern_return_t?
    private var cpuHistory: [Sample] = []
    private var memoryHistory: [Sample] = []

    private struct CPUTicks {
        var user: UInt32
        var system: UInt32
        var nice: UInt32
        var idle: UInt32
    }

    private struct CPUUsage {
        let total: Double
        let perCore: [Double]
    }

    private struct VMSnapshot {
        let free: UInt64
        let active: UInt64
        let inactive: UInt64
        let wired: UInt64
        let compressed: UInt64
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
        thermalObserver = nil
        previousTicks = []
    }

    // MARK: - Sběr

    private func refresh() {
        let info = ProcessInfo.processInfo
        let now = Date()
        var m: [Metric] = []

        // Teplota: jediné, co iOS veřejně dává, je čtyřstupňová škála.
        m.append(.available("thermal", "Stupeň zahřívání", thermalText(info.thermalState),
                            source: "ProcessInfo.thermalState"))

        // CPU
        m.append(.available("cores", "Jádra CPU", "\(info.activeProcessorCount) aktivních z \(info.processorCount)",
                            source: "ProcessInfo.processorCount"))
        if let p = Sysctl.integer("hw.perflevel0.physicalcpu"), let e = Sysctl.integer("hw.perflevel1.physicalcpu") {
            m.append(.available("layout", "Rozložení jader", "\(p) výkonná + \(e) úsporná",
                                source: "sysctl hw.perflevel*"))
        }

        if let usage = sampleSystemCPU() {
            cpuHistory.append(Sample(date: now, value: usage.total))
            trim(&cpuHistory)
            m.append(.derived("cpu", "Zatížení CPU (celý systém)", Fmt.percent(usage.total, 0),
                              note: "Rozdíl tiků host_processor_info za poslední sekundu"))
            m.append(.derived("percore", "Zatížení po jádrech",
                              usage.perCore.map { Fmt.num($0, 0) }.joined(separator: " · ") + " %",
                              note: "Stejný zdroj po jednotlivých jádrech, pořadí dle jádra"))
        } else if let err = cpuReadError {
            m.append(.unavailable("cpu", "Zatížení CPU (celý systém)",
                                  "host_processor_info vrátilo chybu \(err); tato verze iOS údaj neposkytuje."))
        } else {
            m.append(.derived("cpu", "Zatížení CPU (celý systém)", "měří se…",
                              note: "Potřebuje dva vzorky tiků v odstupu 1 s"))
        }

        if let appCPU = sampleAppCPU() {
            m.append(.available("appcpu", "Zatížení CPU (tato aplikace)", Fmt.percent(appCPU, 1),
                                source: "thread_info(THREAD_BASIC_INFO)"))
        }

        // Paměť
        let physical = info.physicalMemory
        m.append(.available("ram", "Fyzická paměť", Fmt.bytes(Int64(physical), memory: true),
                            source: "ProcessInfo.physicalMemory"))
        if let vm = sampleVM() {
            let used = vm.active + vm.wired + vm.compressed
            memoryHistory.append(Sample(date: now, value: Double(used) / Double(physical) * 100))
            trim(&memoryHistory)
            m.append(.derived("used", "Použitá paměť", Fmt.bytes(Int64(used), memory: true),
                              note: "aktivní + pevně přidělená + komprimovaná (host_statistics64)"))
            m.append(.available("free", "Volná paměť", Fmt.bytes(Int64(vm.free), memory: true),
                                source: "host_statistics64 free_count"))
            m.append(.available("inactive", "Neaktivní (uvolnitelná)", Fmt.bytes(Int64(vm.inactive), memory: true),
                                source: "host_statistics64 inactive_count"))
            m.append(.available("wired", "Pevně přidělená (wired)", Fmt.bytes(Int64(vm.wired), memory: true),
                                source: "host_statistics64 wire_count"))
            m.append(.available("compressed", "Komprimovaná", Fmt.bytes(Int64(vm.compressed), memory: true),
                                source: "host_statistics64 compressor_page_count"))
        } else {
            m.append(.unavailable("vm", "Statistika paměti", "host_statistics64 vrátilo chybu."))
        }
        if let footprint = appFootprint() {
            m.append(.available("appmem", "Paměť této aplikace", Fmt.bytes(Int64(footprint), memory: true),
                                source: "task_info phys_footprint"))
        }

        // Čas
        m.append(.available("uptime", "Doba běhu (bdělý stav)", Fmt.duration(info.systemUptime),
                            source: "ProcessInfo.systemUptime"))
        if let boot = Sysctl.bootTime() {
            m.append(.available("boot", "Poslední start", Fmt.date(boot), source: "sysctl kern.boottime"))
            m.append(.derived("wall", "Doba od startu (včetně spánku)", Fmt.duration(now.timeIntervalSince(boot)),
                              note: "Nyní − kern.boottime"))
        }
        m.append(.available("os", "Systém", "iOS \(info.operatingSystemVersionString)", source: "ProcessInfo"))
        if let build = Sysctl.string("kern.osversion") {
            m.append(.available("build", "Sestavení systému", build, source: "sysctl kern.osversion"))
        }

        // Frekvence: zkusíme, ale na iOS to selže. Výsledek ukážeme podle pravdy.
        if let freq = Sysctl.integer("hw.cpufrequency"), freq > 0 {
            m.append(.available("freq", "Frekvence CPU", Fmt.num(Double(freq) / 1e9, 2) + " GHz",
                                source: "sysctl hw.cpufrequency"))
        } else {
            m.append(.unavailable("freq", "Frekvence CPU",
                                  "sysctl hw.cpufrequency na iOS vrací chybu; takt není zveřejněn."))
        }

        m += [
            .unavailable("soctemp", "Teplota CPU / GPU / SoC (°C)",
                         "iOS nemá veřejný teploměr. Jediný signál je čtyřstupňový thermalState výše."),
            .unavailable("procs", "Seznam procesů a jejich zátěž",
                         "Sandbox: aplikace vidí jen svůj vlastní proces."),
            .unavailable("gpu", "Vytížení GPU",
                         "Bez veřejného API; Metal counters měří jen práci vlastní aplikace."),
            .unavailable("ane", "Vytížení Neural Engine", "Bez veřejného API."),
            .unavailable("pressure", "Tlak paměti v číslech",
                         "iOS swap nepoužívá; „tlak“ dostane aplikace jen jako varování didReceiveMemoryWarning."),
        ]

        metrics = m
        series = [
            MetricSeries(id: "cpu", name: "CPU (systém)", unit: "%", samples: cpuHistory, range: 0...100),
            MetricSeries(id: "mem", name: "Použitá paměť", unit: "%", samples: memoryHistory, range: 0...100),
        ]
    }

    private func trim(_ samples: inout [Sample]) {
        if samples.count > 120 { samples.removeFirst(samples.count - 120) }
    }

    private func thermalText(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Normální"
        case .fair: return "Zvýšený"
        case .serious: return "Vážný"
        case .critical: return "Kritický"
        @unknown default: return "Neznámý"
        }
    }

    // MARK: - Mach API

    private func readTicks() -> [CPUTicks]? {
        var cpuInfo: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        var cpuCount: natural_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &cpuInfo, &infoCount)
        guard kr == KERN_SUCCESS, let cpuInfo else {
            cpuReadError = kr
            return nil
        }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.size))
        }
        cpuReadError = nil
        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { i in
            let b = i * stride
            return CPUTicks(
                user: UInt32(bitPattern: cpuInfo[b + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: cpuInfo[b + Int(CPU_STATE_SYSTEM)]),
                nice: UInt32(bitPattern: cpuInfo[b + Int(CPU_STATE_NICE)]),
                idle: UInt32(bitPattern: cpuInfo[b + Int(CPU_STATE_IDLE)])
            )
        }
    }

    private func sampleSystemCPU() -> CPUUsage? {
        guard let current = readTicks() else { return nil }
        defer { previousTicks = current }
        guard previousTicks.count == current.count, !previousTicks.isEmpty else { return nil }

        var perCore: [Double] = []
        var busyTotal = 0.0
        var allTotal = 0.0
        for (p, c) in zip(previousTicks, current) {
            let busy = Double(c.user &- p.user) + Double(c.system &- p.system) + Double(c.nice &- p.nice)
            let idle = Double(c.idle &- p.idle)
            let total = busy + idle
            perCore.append(total > 0 ? busy / total * 100 : 0)
            busyTotal += busy
            allTotal += total
        }
        return CPUUsage(total: allTotal > 0 ? busyTotal / allTotal * 100 : 0, perCore: perCore)
    }

    private func sampleAppCPU() -> Double? {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS, let threadList else {
            return nil
        }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threadList),
                          vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.size))
        }
        var total = 0.0
        for i in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(threadList[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            guard kr == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 else { continue }
            total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
        }
        return total
    }

    private func sampleVM() -> VMSnapshot? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        return VMSnapshot(
            free: UInt64(stats.free_count) * page,
            active: UInt64(stats.active_count) * page,
            inactive: UInt64(stats.inactive_count) * page,
            wired: UInt64(stats.wire_count) * page,
            compressed: UInt64(stats.compressor_page_count) * page
        )
    }

    private func appFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }
}
