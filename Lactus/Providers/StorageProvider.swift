import Foundation
import Observation

/// Úložiště přes URLResourceValues na vlastním kontejneru aplikace.
/// Hodnoty platí pro celý svazek, protože iPhone má jeden datový oddíl.
@Observable @MainActor
final class StorageProvider: SensorProvider {
    let id = "storage"
    let title = "Úložiště"
    let systemImage = "internaldrive"
    private(set) var metrics: [Metric] = []

    private var timer: Timer?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        var m: [Metric] = []
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityForOpportunisticUsageKey,
            .volumeNameKey,
            .volumeSupportsFileCloningKey,
            .volumeIsEncryptedKey,
        ]

        do {
            let v = try url.resourceValues(forKeys: keys)
            if let total = v.volumeTotalCapacity {
                m.append(.available("total", "Celková kapacita", Fmt.bytes(Int64(total)),
                                    source: "volumeTotalCapacity"))
                if let important = v.volumeAvailableCapacityForImportantUsage {
                    m.append(.available("important", "Volné (důležitá data)", Fmt.bytes(important),
                                        source: "volumeAvailableCapacityForImportantUsage"))
                    let used = Int64(total) - important
                    m.append(.derived("used", "Obsazeno",
                                      Fmt.bytes(used) + " (" + Fmt.percent(Double(used) / Double(total) * 100, 0) + ")",
                                      note: "celkem − volné pro důležitá data; zahrnuje i smazatelnou mezipaměť"))
                }
            }
            if let avail = v.volumeAvailableCapacity {
                m.append(.available("avail", "Volné (bez mazání mezipaměti)", Fmt.bytes(Int64(avail)),
                                    source: "volumeAvailableCapacity"))
            }
            if let opp = v.volumeAvailableCapacityForOpportunisticUsage {
                m.append(.available("opp", "Volné (nepovinná data)", Fmt.bytes(opp),
                                    source: "volumeAvailableCapacityForOpportunisticUsage"))
            }
            if let name = v.volumeName {
                m.append(.available("name", "Název svazku", name, source: "volumeName"))
            }
            if let clone = v.volumeSupportsFileCloning {
                m.append(.available("apfs", "Klonování souborů (APFS)", clone ? "Ano" : "Ne",
                                    source: "volumeSupportsFileCloning"))
            }
            if let enc = v.volumeIsEncrypted {
                m.append(.available("enc", "Šifrovaný svazek", enc ? "Ano" : "Ne", source: "volumeIsEncrypted"))
            }
        } catch {
            m.append(.unavailable("err", "Údaje o svazku", "resourceValues selhalo: \(error.localizedDescription)"))
        }

        m += [
            .unavailable("breakdown", "Rozpis podle aplikací a kategorií",
                         "Sandbox: aplikace vidí jen vlastní kontejner. Rozpis je jen v Nastavení › Obecné › Úložiště."),
            .unavailable("health", "Zdraví NAND / počet přepisů", "Bez veřejného API."),
            .unavailable("speed", "Rychlost čtení a zápisu", "Bez API; měřit lze jen vlastní soubory, což úložiště opotřebovává."),
            .unavailable("vendor", "Výrobce a model paměti", "Bez veřejného API."),
        ]

        metrics = m
    }
}
