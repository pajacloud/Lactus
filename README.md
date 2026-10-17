# Lactus

Poctivý monitor iPhonu. Čte **všechno, co iOS veřejnými API dává**, ukáže zdroj každé hodnoty a to, co systém neposkytuje, nechá v **šedé zóně** s důvodem. Nic si nevymýšlí.

Cíl: iPhone 17 Pro, iOS 17 a novější, Xcode 16 a novější.

## Princip

1. **Jen veřejná API.** Žádný IOKit, žádné privátní frameworky. Všechno by prošlo App Storem.
2. **Nic si nevymýšlíme.** Každý řádek má drobně uvedený zdroj (`UIDevice.batteryLevel`, `host_statistics64`…).
3. **Odvozené je označené.** Rychlost vybíjení, zatížení CPU nebo obsazené úložiště počítá aplikace sama a říká z čeho (ikona ƒ).
4. **Souhlas až na vyžádání.** Poloha a „Pohyb a fitness“ se žádají tlačítkem v sekci, ne při startu.
5. **Nic neopouští telefon.** Žádná síť, analytika ani ukládání. Grafy žijí jen v paměti za běhu.

## Co ukazuje

| Sekce | Čte (veřejné API) | Odvozuje | Šedá zóna (iOS neposkytuje) |
|---|---|---|---|
| Baterie | úroveň (1 %), stav nabíjení, režim nízké spotřeby | rychlost změny %/h, odhad do vybití/nabití | zdraví, cykly, teplota, napětí, proud, mAh, W nabíječky, limit nabíjení |
| Systém | thermalState, jádra (vč. výkonná/úsporná), RAM, volná/wired/komprimovaná paměť, paměť a CPU vlastní aplikace, uptime, boot, build | zatížení CPU celého systému a po jádrech (host_processor_info), použitá paměť | teplota °C, frekvence CPU, procesy, GPU/ANE vytížení |
| Úložiště | celkem, volné (3 varianty), název svazku, APFS, šifrování | obsazeno | rozpis podle aplikací, zdraví NAND, rychlost |
| Displej | jas, rozlišení, max Hz, gamut, HDR headroom, zrcadlení, senzor přiblížení (přepínač) | frekvence přidělená aplikaci (CADisplayLink) | lux, True Tone, skutečná frekvence panelu, nity |
| Pohyb a tlak | akcelerometr, gyroskop, magnetometr, attitude, gravitace, kompas ze senzorů, barometr, relativní výška; po souhlasu absolutní výška, kroky, patra, tempo, aktivita | velikost zrychlení a pole | teplota a výrobce senzorů, surová data, >100 Hz |
| Poloha | oprávnění, souřadnice, přesnost, výška (MSL i WGS84), rychlost, kurz, patro, původ fixu, kompas | stáří fixu | satelity, SNR, DOP, typ fixu, zdroj (GPS/Wi‑Fi/BTS) |
| Síť | stav, rozhraní, drahé/nízká data, IPv4/6/DNS, brány, lokální IP, mobilní technologie (5G/LTE…), omezení dat | — | SSID/BSSID a síla Wi‑Fi (bez entitlementu), dBm, Cell ID, operátor (od iOS 16 jen „--“) |
| Zvuk | hlasitost, výstupní a vstupní porty, dostupné mikrofony, vzorkování, latence, buffer, kanály, stav oprávnění mikrofonu | — | hladina mikrofonu (aplikace nenahrává), baterie sluchátek, dB SPL |
| Zařízení | identifikátor modelu, kód desky, systém, IDFV, architektura, cache, GPU přes Metal (název, rodina, ray tracing), biometrie, kamery (rozlišení, zoom, fps, ISO, blesk) | marketingový název z tabulky v aplikaci | sériové číslo, IMEI, vlastní název (od iOS 16), baseband, Neural Engine, název čipu |

Záložka **Neposkytuje** shrnuje celou šedou zónu na jednom místě s důvody.

## Instalace na iPhone

Každý push na GitHub spustí workflow **Build** na macOS runneru. Ten ověří, že se projekt přeloží, a přiloží artefakt `Lactus-unsigned-ipa`.

### Varianta A: s Macem (doporučeno)

1. Otevři `Lactus.xcodeproj` v Xcode 16 nebo novějším.
2. V targetu Lactus › Signing & Capabilities vyber svůj **Team**. Stačí bezplatné Apple ID. Když Xcode hlásí obsazené bundle ID, změň `cloud.paja.Lactus` na cokoli vlastního.
3. Na iPhonu zapni **Režim pro vývojáře** v Nastavení › Soukromí a zabezpečení a restartuj ho.
4. Připoj iPhone kabelem, vyber ho nahoře jako cíl a dej ⌘R.
5. Při prvním spuštění povol certifikát v Nastavení › Obecné › VPN a správa zařízení.

S bezplatným Apple ID aplikace vyprší po 7 dnech; stačí ji z Xcode spustit znovu. S placeným Developer Programem platí rok.

### Varianta B: bez Macu (Windows nebo Linux)

1. Na GitHubu otevři Actions › Build › poslední zelený běh a stáhni artefakt `Lactus-unsigned-ipa`. Rozbal zip, uvnitř je `Lactus-unsigned.ipa`.
2. Nainstaluj [Sideloadly](https://sideloadly.io) nebo [AltStore](https://altstore.io) na počítač.
3. Připoj iPhone, přetáhni IPA do Sideloadly a přihlas se svým Apple ID. Nástroj aplikaci podepíše a nainstaluje.
4. Na iPhonu zapni Režim pro vývojáře a povol certifikát jako ve variantě A.

Platí stejný sedmidenní limit bezplatného Apple ID.

Kdyby Xcode projekt odmítl otevřít, je přibalený `project.yml` pro [XcodeGen](https://github.com/yonaskolb/XcodeGen): `xcodegen generate`.

## Struktura

```
Lactus/
  LactusApp.swift            vstup, start/stop podle scenePhase
  Models/Metric.swift        Metric, MetricStatus (available / derived / permission / unsupported / unavailable)
  Models/SensorProvider.swift protokol poskytovatele + Monitor
  Providers/*.swift          jeden soubor na sekci (Battery, System, Storage, Display, Motion, Location, Network, Audio, Hardware)
  Views/*.swift              seznam sekcí, řádky metrik, šedá zóna, O aplikaci
  Support/Sysctl.swift, Fmt.swift
Support/Info.plist           texty oprávnění, CADisableMinimumFrameDurationOnPhone
```

Nový údaj se přidává tak, že poskytovatel vrátí další `Metric`. UI o něm nic vědět nemusí; podle stavu skončí buď v hlavní části, nebo v šedé zóně.

## Co by šlo přidat dál

- Widget / Live Activity s úrovní baterie a thermalState.
- Export historie grafů do CSV (zatím záměrně nic neukládáme).
- Headphone motion (AirPods) přes `CMHeadphoneMotionManager`.
- Entitlement „Access Wi‑Fi Information“, který odemkne SSID a relativní sílu Wi‑Fi.
