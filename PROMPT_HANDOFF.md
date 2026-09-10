# Übergabe / Handoff — Datenmonitor-Widget (macOS)

Dieses Dokument bildet den **kompletten aktuellen Stand** des Projekts ab. Es ist dafür
gedacht, es einer anderen Person oder KI zu geben, damit alle vom Gleichen reden. Es
enthält Ziel, alle getroffenen Entscheidungen samt Begründung, den vollständigen
Quellcode, Build/Install und offene Punkte. Wer damit weiterarbeitet, braucht sonst nichts.

---

## 1. Ziel

Ein **datenschutzfreundliches, quelloffenes Menüleisten-Widget** für macOS, das den
mobilen Datenverbrauch überwacht — vor allem über einen iPhone-Hotspot, weil monatlich nur
ein begrenztes Volumen (Limit 10 GB) verfügbar ist. Nutzer arbeitet auf einem MacBook Air,
Systemsprache Englisch, hat LuLu Firewall installiert. Keine proprietäre Software
(kein Little Snitch/TripMode/SwiftBar), möglichst nur macOS-Bordmittel.

## 2. Endgültiges Design (nach mehreren Iterationen)

Statt eines großen Skript-Pakets (Daemon + TUI + Config) wurde bewusst auf **KISS**
reduziert: **ein einziges Menüleisten-Widget**, das gleichzeitig der Tracker ist.

- Menüleiste im **Stats-Stil**: untere Zeile = Verbrauch (GB) des aktuellen Netzes im
  laufenden Monat, obere Zeile klein = Netz-Name. Kein Emoji.
- Klick öffnet ein Menü: aktuelles Netz + alle Netze des Monats + Untermenü frühere Monate.
- Jedes WLAN wird **automatisch getrennt** gezählt (keine manuelle Konfiguration).
- Dezenter 10-GB-Indikator: Zahl wird rot über Limit.

## 3. Zentrale technische Entscheidungen (WICHTIG für jede Weiterarbeit)

1. **Sprache: Swift, kompiliert mit `swiftc`** (Xcode Command Line Tools). Grund: echtes
   natives Menüleisten-Widget (NSStatusItem) ohne Fremdpakete. `swiftc` ist Apple-Bordmittel.
   Kompiliert wird **einmal** pro Codeänderung, nicht bei jedem Start.

2. **Datenerfassung: `netstat -ibn`.** Kumulative Byte-Zähler der Schnittstelle. Es wird
   gezielt die Link-Layer-Zeile (`<Link#n>`) gelesen (Spalte 7 = Ibytes/Download,
   Spalte 10 = Obytes/Upload); dadurch IPv4+IPv6 zusammen, ohne Doppelzählung. Verbrauch =
   Summe von **Deltas** (Prinzip wie vnstat). `ifconfig` liefert unter macOS KEINE
   Byte-Zähler; `nettop` resettet — daher nicht geeignet.

3. **Reset-Erkennung:** Ist der aktuelle Roh-Zähler kleiner als der letzte (Reboot /
   Interface-Zyklus), gilt Delta = aktueller Wert. Verhindert Fehlzählung nach Neustart.

4. **Netz-Identität OHNE Standort-Berechtigung (Kernproblem, jetzt gelöst):**
   Seit macOS 14.4/Sequoia gibt das System den WLAN-**Namen (SSID)** nur an Apps mit
   **Ortungsdienste-Zugriff** heraus (betrifft `networksetup`, `airport`, CoreWLAN). Ein
   unsigniertes Terminal-Binary bekommt das nicht → anfangs zeigte das Widget „kein WLAN"
   und zählte nichts. Lösung: Ein Netz wird über die **Router-MAC-Adresse** (`arp` auf das
   Gateway) eindeutig identifiziert — immer lesbar, keine Berechtigung nötig. Das ist der
   Speicher-Schlüssel. Der **Anzeigename** ist die echte SSID, falls doch verfügbar, sonst
   eine Heuristik: Gateway `172.20.10.x` → „iPhone-Hotspot"; `192.168.43.1` →
   „Android-Hotspot"; sonst „WLAN ·<MAC-Ende>".

5. **Menüleisten-Farbe: Template-Bild.** Der Widget-Text wird als NSImage gezeichnet und
   `img.isTemplate = true` gesetzt → macOS tönt es automatisch passend zur Menüleiste
   (dunkel bei hell, hell bei dunkel), wie CPU/GPU-Anzeigen. Die obere Zeile ist über
   Deckkraft 0.6 dezenter. Nur über Limit: `isTemplate = false` und feste rote Zahl.

6. **Persistenz:** JSON unter `~/Library/Application Support/Datenmonitor/usage.json`.
   Struktur: letzte Roh-Zähler + `months[YYYY-MM][netKey] = {down,up}` + `names[netKey]`.

7. **Autostart: launchd LaunchAgent** (`RunAtLoad`, `KeepAlive`, `.accessory` → kein
   Dock-Icon). Installiert von `install-widget.sh`.

8. **Datenschutz:** Kein Netzwerkzugriff, keine externen APIs, keine Telemetrie, alles lokal.
   Ressourcen: alle 20 s ein paar kurze Bordmittel-Aufrufe, im Mittel <0,1 % CPU, ~10–25 MB
   RAM, 0 Netz.

## 4. Aktueller Feinstand (zuletzt eingestellt)

- Obere Zeile (Netz-Name): `NSFont.systemFont(ofSize: 7, weight: .regular)`, Deckkraft 0.6.
- Untere Zeile (GB): `NSFont.systemFont(ofSize: 11, weight: .semibold)`.
- `img.isTemplate = !warn` (adaptive Farbe; rot nur über Limit).
- `LIMIT_GB = 10`, `SAMPLE_INTERVAL = 20`.

## 5. Bekannte Einschränkungen / bewusst offen

- Echter SSID-Name nur mit Ortungsdienste-Freigabe möglich; das bräuchte eine signierte
  `.app` mit CoreLocation. Bewusst NICHT umgesetzt (Ziel: ohne Berechtigung). Das war der
  letzte offene Diskussionspunkt — Nutzer kann das später noch wählen.
- Zwei Netze mit identischem Router nicht trennbar.
- Interface-Zähler messen allen Verkehr inkl. Overhead → Providerwert kann leicht abweichen.
- Menüleiste ist ~22 pt hoch → untere Schrift sinnvoll max. ~12 pt.

## 6. Build / Install / Update

Drei Dateien in einen Ordner: `DatenmonitorWidget.swift`, `install-widget.sh`,
`at.datenmonitor.widget.plist`. Dann:

    chmod +x install-widget.sh
    ./install-widget.sh

Update nach Codeänderung: erneut `./install-widget.sh`. Wenn `bootstrap` mit
„Input/output error" abbricht (Agent schon geladen), laufende Version neu starten:

    launchctl kickstart -k gui/$(id -u)/at.datenmonitor.widget

Voraussetzung: `swiftc` (sonst `xcode-select --install`).

## 7. Vollständiger Quellcode

### DatenmonitorWidget.swift
```swift
// DatenmonitorWidget.swift
// ---------------------------------------------------------------------------
// Menüleisten-Widget für den WLAN-Datenverbrauch — im Stats-Stil.
// Zeigt unten groß den Verbrauch (GB) und darüber klein das aktuelle WLAN.
// Klick öffnet ein Menü mit allen Netzen des Monats + frühere Monate.
//
// Netz-Erkennung OHNE Standort-Berechtigung:
//   - Identität eines Netzes  = MAC-Adresse des Routers (via `arp`) — immer lesbar.
//   - Anzeigename             = echte SSID falls verfügbar, sonst Heuristik
//     (iPhone-Hotspot an Gateway 172.20.10.1, Android-Hotspot an 192.168.43.1),
//     sonst "WLAN ·<MAC-Ende>".
//
// Nur Apple-Bordmittel: swiftc, AppKit, Foundation. Kein Netzwerk, keine Telemetrie.
// Daten lokal unter ~/Library/Application Support/Datenmonitor/usage.json
//
// Bauen:  swiftc -O -o datenmonitor-widget DatenmonitorWidget.swift -framework AppKit
// Lizenz: Public Domain / CC0
// ---------------------------------------------------------------------------

import AppKit
import Foundation

// MARK: - Konfiguration
let LIMIT_GB: Double = 10.0
let SAMPLE_INTERVAL: TimeInterval = 20
let GIB: Double = 1_073_741_824

// MARK: - Datenmodell
struct Usage: Codable {
    var down: UInt64 = 0
    var up: UInt64 = 0
    var total: UInt64 { down &+ up }
}

struct Store: Codable {
    var lastDown: UInt64? = nil
    var lastUp: UInt64? = nil
    var months: [String: [String: Usage]] = [:]   // "YYYY-MM" -> netKey -> Usage
    var names: [String: String] = [:]             // netKey -> Anzeigename
}

// MARK: - Persistenz
final class Storage {
    static let shared = Storage()
    private let fileURL: URL
    var store = Store()

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Datenmonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("usage.json")
        load()
    }
    func load() {
        guard let d = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(Store.self, from: d) else { return }
        store = s
    }
    func save() {
        guard let d = try? JSONEncoder().encode(store) else { return }
        try? d.write(to: fileURL, options: .atomic)
    }
    var dataDirectory: URL { fileURL.deletingLastPathComponent() }
}

// MARK: - Systemabfragen (rein lesend, kein Netzwerk)
enum Sys {
    static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static var cachedIface: String?
    static func wifiInterface() -> String {
        if let c = cachedIface { return c }
        let out = run("/usr/sbin/networksetup", ["-listallhardwareports"])
        let lines = out.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            if line.contains("Hardware Port: Wi-Fi") || line.contains("Hardware Port: AirPort") {
                if i + 1 < lines.count {
                    let parts = lines[i + 1].components(separatedBy: " ")
                    if let dev = parts.last, !dev.isEmpty { cachedIface = dev; return dev }
                }
            }
        }
        cachedIface = "en0"; return "en0"
    }

    /// IPv4-Adresse der Schnittstelle (leer = nicht mit WLAN verbunden).
    static func ifaceIP(_ iface: String) -> String? {
        let s = run("/usr/sbin/ipconfig", ["getifaddr", iface]).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// Gateway-IP des Default-Routes.
    static func gateway() -> String? {
        let out = run("/sbin/route", ["-n", "get", "default"])
        for line in out.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("gateway:") {
                return t.replacingOccurrences(of: "gateway:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Router-MAC über ARP (stabile Netz-Identität, keine Berechtigung nötig).
    static func routerMAC(_ gw: String) -> String? {
        let out = run("/usr/sbin/arp", ["-n", gw])
        // Beispiel: "? (172.20.10.1) at 8e:12:aa:bb:cc:dd on en0 ifscope [ethernet]"
        guard let r = out.range(of: " at ") else { return nil }
        let rest = out[r.upperBound...]
        let mac = rest.split(separator: " ").first.map(String.init) ?? ""
        if mac.isEmpty || mac.contains("incomplete") { return nil }
        return mac
    }

    /// Echte SSID, falls das System sie herausgibt (macOS 15: oft nur mit Ortungsfreigabe).
    static func ssid(_ iface: String) -> String? {
        // 1) networksetup
        let a = run("/usr/sbin/networksetup", ["-getairportnetwork", iface])
        if let r = a.range(of: "Current Wi-Fi Network: ") {
            let s = a[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty, s != "<redacted>" { return s }
        }
        // 2) ipconfig getsummary
        let b = run("/usr/sbin/ipconfig", ["getsummary", iface])
        for line in b.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("SSID :") || t.hasPrefix("ssid_str :") {
                let v = t.components(separatedBy: ":").dropFirst().joined(separator: ":")
                    .trimmingCharacters(in: .whitespaces)
                if !v.isEmpty, v != "<redacted>" { return v }
            }
        }
        return nil
    }

    /// (Ibytes, Obytes) der <Link#n>-Zeile einer Schnittstelle.
    static func counters(_ iface: String) -> (down: UInt64, up: UInt64)? {
        let out = run("/usr/sbin/netstat", ["-ibn"])
        for line in out.components(separatedBy: "\n") {
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard f.count >= 10 else { continue }
            if f[0] == iface, f[2].hasPrefix("<Link"),
               let d = UInt64(f[6]), let u = UInt64(f[9]) { return (d, u) }
        }
        return nil
    }
}

// MARK: - Netz-Identität (Schlüssel + Anzeigename)
struct Net { let key: String; let name: String }

enum NetID {
    static func current() -> Net? {
        let iface = Sys.wifiInterface()
        guard Sys.ifaceIP(iface) != nil else { return nil }   // nicht verbunden

        let gw = Sys.gateway()
        let mac = gw.flatMap { Sys.routerMAC($0) }
        // Schlüssel: bevorzugt Router-MAC (stabil, ohne Rechte), sonst Gateway, sonst "wlan"
        let key = mac ?? gw ?? "wlan"

        // Anzeigename: echte SSID > Hotspot-Heuristik > MAC-Kürzel
        let name: String
        if let s = Sys.ssid(iface) {
            name = s
        } else if let gw = gw, gw.hasPrefix("172.20.10.") {
            name = "iPhone-Hotspot"
        } else if let gw = gw, gw == "192.168.43.1" {
            name = "Android-Hotspot"
        } else if let mac = mac {
            let tail = mac.split(separator: ":").suffix(2).joined(separator: ":")
            name = "WLAN ·\(tail)"
        } else {
            name = "WLAN"
        }
        return Net(key: key, name: name)
    }
}

// MARK: - Zähl-Logik
enum Meter {
    static func monthKey(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f.string(from: date)
    }

    static func sample() {
        let s = Storage.shared
        let iface = Sys.wifiInterface()
        guard let cur = Sys.counters(iface) else { return }
        let net = NetID.current()
        let key = monthKey()

        if let ld = s.store.lastDown, let lu = s.store.lastUp {
            let dDown: UInt64 = cur.down >= ld ? cur.down - ld : cur.down
            let dUp:   UInt64 = cur.up   >= lu ? cur.up   - lu : cur.up
            if let net = net, (dDown > 0 || dUp > 0) {
                var month = s.store.months[key] ?? [:]
                var u = month[net.key] ?? Usage()
                u.down &+= dDown; u.up &+= dUp
                month[net.key] = u
                s.store.months[key] = month
                s.store.names[net.key] = net.name     // Anzeigename aktuell halten
            }
        }
        s.store.lastDown = cur.down
        s.store.lastUp = cur.up
        s.save()
    }

    static func usage(month: String, key: String) -> Usage? {
        Storage.shared.store.months[month]?[key]
    }
    static func name(for key: String) -> String {
        Storage.shared.store.names[key] ?? key
    }
}

// MARK: - Formatierung
func gb(_ bytes: UInt64) -> String { String(format: "%.2f GB", Double(bytes) / GIB) }

// MARK: - Menüleisten-App
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(); menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageOnly
        Meter.sample(); updateTitle()
        timer = Timer.scheduledTimer(withTimeInterval: SAMPLE_INTERVAL, repeats: true) { [weak self] _ in
            Meter.sample(); self?.updateTitle()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    // Zwei Zeilen im Stats-Stil: oben klein das Netz, unten groß die GB.
    func updateTitle() {
        let net = NetID.current()
        let topText = net?.name ?? "kein WLAN"
        var bottomText = "–"
        var warn = false
        if let net = net {
            let u = Meter.usage(month: Meter.monthKey(), key: net.key) ?? Usage()
            bottomText = gb(u.total)
            warn = Double(u.total) / GIB > LIMIT_GB
        }
        statusItem.button?.image = Self.renderTwoLine(top: topText, bottom: bottomText, warn: warn)
    }

    static func renderTwoLine(top: String, bottom: String, warn: Bool) -> NSImage {
        let topFont = NSFont.systemFont(ofSize: 7, weight: .regular)    // Netz-Name (obere Zeile)
        let botFont = NSFont.systemFont(ofSize: 11, weight: .semibold)  // GB-Wert (untere Zeile)
        // Template-Bild: Farbe egal, macOS tönt es passend zur Menüleiste (Light/Dark).
        // Obere Zeile mit weniger Deckkraft -> wirkt dezenter (wie das CPU/GPU-Label).
        let topColor = NSColor.black.withAlphaComponent(0.6)
        let botColor = warn ? NSColor.systemRed : NSColor.black
        let topStr = NSAttributedString(string: top, attributes: [.font: topFont, .foregroundColor: topColor])
        let botStr = NSAttributedString(string: bottom, attributes: [.font: botFont, .foregroundColor: botColor])
        let ts = topStr.size(), bs = botStr.size()
        let w = ceil(max(ts.width, bs.width)) + 8
        let h = max(NSStatusBar.system.thickness, 22)

        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        // unten: GB, oben darüber: Netzname
        botStr.draw(at: NSPoint(x: (w - bs.width) / 2, y: 0))
        topStr.draw(at: NSPoint(x: (w - ts.width) / 2, y: h - ts.height + 1))
        img.unlockFocus()
        img.isTemplate = !warn   // adaptiv (folgt der Menüleiste); nur bei Limit fest rot
        return img
    }

    // MARK: Menü
    func menuNeedsUpdate(_ menu: NSMenu) {
        Meter.sample()
        menu.removeAllItems()

        let net = NetID.current()
        let curKey = Meter.monthKey()

        let head = NSMenuItem(title: "Aktuelles WLAN: \(net?.name ?? "– keins")", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        if let net = net {
            let u = Meter.usage(month: curKey, key: net.key) ?? Usage()
            let sub = NSMenuItem(title: "   \(gb(u.total))   (↓ \(gb(u.down))  ↑ \(gb(u.up)))",
                                 action: nil, keyEquivalent: "")
            sub.isEnabled = false
            menu.addItem(sub)
        }

        menu.addItem(.separator())
        let title = NSMenuItem(title: "Diesen Monat (\(prettyMonth(curKey))):", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        addList(to: menu, monthKey: curKey, highlight: net?.key)

        let pastKeys = Storage.shared.store.months.keys.filter { $0 != curKey }.sorted(by: >)
        if !pastKeys.isEmpty {
            menu.addItem(.separator())
            let root = NSMenuItem(title: "Frühere Monate", action: nil, keyEquivalent: "")
            let pm = NSMenu()
            for mk in pastKeys {
                let it = NSMenuItem(title: prettyMonth(mk), action: nil, keyEquivalent: "")
                let sub = NSMenu()
                addList(to: sub, monthKey: mk, highlight: nil)
                it.submenu = sub
                pm.addItem(it)
            }
            root.submenu = pm
            menu.addItem(root)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Jetzt aktualisieren", action: #selector(refresh), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Datenordner öffnen", action: #selector(openFolder), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != nil { item.target = self }
    }

    func addList(to menu: NSMenu, monthKey: String, highlight: String?) {
        guard let month = Storage.shared.store.months[monthKey], !month.isEmpty else {
            let e = NSMenuItem(title: "   (noch keine Daten)", action: nil, keyEquivalent: "")
            e.isEnabled = false; menu.addItem(e); return
        }
        for (key, u) in month.sorted(by: { $0.value.total > $1.value.total }) {
            let over = Double(u.total) / GIB > LIMIT_GB
            let extra = over ? "   (über \(Int(LIMIT_GB)) GB)" : ""
            let it = NSMenuItem(title: "\(Meter.name(for: key)) — \(gb(u.total))\(extra)",
                                action: nil, keyEquivalent: "")
            it.isEnabled = false
            if key == highlight { it.state = .on }   // nativer Haken beim aktuellen Netz
            menu.addItem(it)
        }
    }

    func prettyMonth(_ key: String) -> String {
        let n = ["Januar","Februar","März","April","Mai","Juni",
                 "Juli","August","September","Oktober","November","Dezember"]
        let p = key.split(separator: "-")
        guard p.count == 2, let m = Int(p[1]), m >= 1, m <= 12 else { return key }
        return "\(n[m-1]) \(p[0])"
    }

    @objc func refresh() { Meter.sample(); updateTitle() }
    @objc func openFolder() { NSWorkspace.shared.open(Storage.shared.dataDirectory) }
}

// MARK: - Start
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AppController()
app.delegate = controller
app.run()
```

### install-widget.sh
```bash
#!/bin/bash
#
# install-widget.sh — Kompiliert und installiert das Datenmonitor-Menüleisten-Widget.
# Nur Apple-Bordmittel (swiftc aus den Xcode Command Line Tools). Keine Fremdpakete.
#
set -eu

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.local/bin"
AGENT_DIR="$HOME/Library/LaunchAgents"
SUPPORT_DIR="$HOME/Library/Application Support/Datenmonitor"
PLIST="at.datenmonitor.widget.plist"
BIN="datenmonitor-widget"

echo "== Datenmonitor-Widget: Installation =="

# 0. Swift-Compiler vorhanden?
if ! command -v swiftc >/dev/null 2>&1; then
  echo "Fehler: 'swiftc' fehlt. Bitte einmalig die Xcode Command Line Tools installieren:"
  echo "    xcode-select --install"
  echo "Danach dieses Skript erneut ausführen."
  exit 1
fi

# 1. Kompilieren
mkdir -p "$BIN_DIR" "$SUPPORT_DIR"
echo "Kompiliere ..."
swiftc -O -o "$BIN_DIR/$BIN" "$SRC_DIR/DatenmonitorWidget.swift" -framework AppKit
chmod +x "$BIN_DIR/$BIN"
echo "Installiert: $BIN_DIR/$BIN"

# 2. launchd-Agent mit echtem Home-Pfad
mkdir -p "$AGENT_DIR"
sed "s|__HOME__|$HOME|g" "$SRC_DIR/$PLIST" > "$AGENT_DIR/$PLIST"

# 3. Laden (bei Bedarf erst entladen)
launchctl bootout "gui/$(id -u)/at.datenmonitor.widget" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT_DIR/$PLIST"

echo ""
echo "Fertig. Das Widget 📶 erscheint jetzt oben rechts in der Menüleiste."
echo ""
echo "Falls die WLAN-Namen leer bleiben (macOS 15): Ortungsdienste für das Programm erlauben"
echo "unter  Systemeinstellungen → Datenschutz & Sicherheit → Ortungsdienste."
echo ""
echo "Beenden/entfernen:  launchctl bootout gui/$(id -u)/at.datenmonitor.widget"
```

### at.datenmonitor.widget.plist
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>at.datenmonitor.widget</string>

    <key>ProgramArguments</key>
    <array>
        <string>__HOME__/.local/bin/datenmonitor-widget</string>
    </array>

    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>

    <key>ProcessType</key>
    <string>Interactive</string>

    <key>StandardOutPath</key>
    <string>__HOME__/Library/Application Support/Datenmonitor/widget.out.log</string>
    <key>StandardErrorPath</key>
    <string>__HOME__/Library/Application Support/Datenmonitor/widget.err.log</string>
</dict>
</plist>
```

## 8. Ideen für später

- Echte SSID via signierter `.app` + Standort-Berechtigung.
- Pro Netz eigener Anzeigename (manuelles Umbenennen).
- Tages-/Wochenstatistik, CSV-Export, prozentuale Warnschwellen.
- Verpacken als `.app` für den Programme-Ordner (dann kein Install-Skript nötig).