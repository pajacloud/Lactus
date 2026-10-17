import SwiftUI

struct AboutView: View {
    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Princip") {
                    principle("1.", "Jen veřejná API.", "Žádný IOKit, žádné privátní frameworky, nic, co by neprošlo App Storem.")
                    principle("2.", "Nic si nevymýšlíme.", "Každá hodnota má uvedený zdroj. Co systém nedává, je v šedé zóně s důvodem.")
                    principle("3.", "Odvozené je označené.", "Rychlost vybíjení nebo zatížení CPU počítáme sami a říkáme z čeho.")
                    principle("4.", "Souhlas až na vyžádání.", "Poloha a Pohyb a fitness se žádají tlačítkem, ne při startu.")
                    principle("5.", "Nic neopouští telefon.", "Žádná síť, analytika ani ukládání. Historie grafů žije jen v paměti za běhu.")
                }
                Section("Proč to tak je") {
                    Text("Na Macu může nástroj jako AlDente číst SMC a IOKit. Na iOS je to zakázané: baterie, teploty, síla signálu a surová GNSS data jsou dostupná jen systému. Aplikace, které tyto hodnoty „ukazují“, je buď odhadují, nebo je opisují z toho, co uživatel vidí v Nastavení. Lactus raději ukáže prázdnou šedou zónu než vymyšlené číslo.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section("Aplikace") {
                    LabeledContent("Verze", value: version)
                    LabeledContent("Minimální iOS", value: "17.0")
                    LabeledContent("Síťová komunikace", value: "žádná")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("O aplikaci")
        }
    }

    private func principle(_ number: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(number).monospacedDigit().foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
