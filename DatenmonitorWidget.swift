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
    var names: [String: String] = [:]             // netKey -> automatischer Name (SSID/Heuristik)
    var aliases: [String: String] = [:]           // netKey -> vom Nutzer vergebener Name

    init() {}

    // Tolerantes Einlesen: fehlende Felder -> Standardwert (kein Datenverlust bei Updates).
    enum CodingKeys: String, CodingKey { case lastDown, lastUp, months, names, aliases }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastDown = try c.decodeIfPresent(UInt64.self, forKey: .lastDown)
        lastUp   = try c.decodeIfPresent(UInt64.self, forKey: .lastUp)
        months   = try c.decodeIfPresent([String: [String: Usage]].self, forKey: .months) ?? [:]
        names    = try c.decodeIfPresent([String: String].self, forKey: .names) ?? [:]
        aliases  = try c.decodeIfPresent([String: String].self, forKey: .aliases) ?? [:]
    }
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
    /// Anzeigename: vom Nutzer vergebener Alias > automatischer Name > Schlüssel.
    static func displayName(for key: String) -> String {
        Storage.shared.store.aliases[key] ?? Storage.shared.store.names[key] ?? key
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
        let topText = net.map { Storage.shared.store.aliases[$0.key] ?? $0.name } ?? "kein WLAN"
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

        let curName = net.map { Storage.shared.store.aliases[$0.key] ?? $0.name } ?? "– keins"
        let head = NSMenuItem(title: "Aktuelles WLAN: \(curName)", action: nil, keyEquivalent: "")
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
            // klickbar: öffnet den Umbenennen-Dialog
            let it = NSMenuItem(title: "\(Meter.displayName(for: key)) — \(gb(u.total))\(extra)",
                                action: #selector(renameNet(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = key
            it.toolTip = "Klicken, um dieses Netz umzubenennen"
            if key == highlight { it.state = .on }   // nativer Haken beim aktuellen Netz
            menu.addItem(it)
        }
    }

    // Netz umbenennen: Klick auf einen Eintrag öffnet ein Eingabefeld.
    @objc func renameNet(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let alert = NSAlert()
        alert.messageText = "Netz umbenennen"
        alert.informativeText = "Eigener Name für dieses WLAN (leer = automatischer Name):"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = Storage.shared.store.aliases[key] ?? Meter.name(for: key)
        alert.accessoryView = field
        alert.addButton(withTitle: "Speichern")
        alert.addButton(withTitle: "Abbrechen")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if v.isEmpty { Storage.shared.store.aliases.removeValue(forKey: key) }
            else { Storage.shared.store.aliases[key] = v }
            Storage.shared.save()
            updateTitle()
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