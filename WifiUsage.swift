// WifiUsage.swift
// ---------------------------------------------------------------------------
// Menüleisten-Widget für den WLAN-Datenverbrauch — im Stats-Stil.
// Oben klein der WLAN-Name, darunter der Verbrauch (GB) im laufenden Monat
// (Darstellung in den Einstellungen wählbar, z. B. zusätzlich mit WLAN-Symbol).
// Klick öffnet ein Menü im Stil des macOS-WLAN-Menüs (Netze wechseln, Verbrauch);
// unten Übersicht + Zahnrad für die Einstellungen (Sprache, Darstellung, Coffee).
// Die Übersicht (eigenes Fenster) zeigt die Statistik: pro Netz, pro Monat, pro Tag.
//
// Netz-Erkennung:
//   - Name = echte SSID über CoreWLAN. macOS gibt sie nur mit Ortungsdienste-Freigabe
//     heraus, deshalb läuft das Widget als kleine Wifi Usage.app (siehe install-widget.sh).
//   - Router-MAC (via `arp`) wird der SSID zugeordnet, damit ältere Einträge
//     (vor der Freigabe gezählt) automatisch unter dem echten Namen zusammenlaufen.
//
// Nur Apple-Bordmittel: swiftc, AppKit, SwiftUI, Charts, CoreWLAN, CoreLocation. Keine Netzwerkaufrufe, keine Telemetrie.
// Daten lokal unter ~/Library/Application Support/Datenmonitor/usage.json
//
// Bauen:  ./install-widget.sh   (baut die .app, signiert sie ad-hoc, richtet Autostart ein)
// Lizenz: PolyForm Noncommercial 1.0.0 (siehe LICENSE.md) — © 2026 Gabriel Suntinger
// ---------------------------------------------------------------------------

import AppKit
import Charts
import CoreLocation
import CoreWLAN
import Foundation
import Network
import SwiftUI

// MARK: - Konfiguration
let SAMPLE_INTERVAL: TimeInterval = 20
let GIB: Double = 1_073_741_824
let SSID_PREFIX = "ssid:"          // Schlüssel für Netze mit bekannter SSID: "ssid:<Name>"
let UNKNOWN_KEY = "unbekannt"       // weder SSID noch Router-MAC ermittelbar
let APP_VERSION = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"

// Buy Me a Coffee: hier deinen eigenen Link eintragen (Anleitung in der README).
let COFFEE_URL = "https://buymeacoffee.com/suntinger"

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
    var days: [String: [String: Usage]] = [:]     // "YYYY-MM-DD" -> netKey -> Usage (für den Tagesverlauf)
    var names: [String: String] = [:]             // netKey -> Ersatzname (Heuristik, alte Daten)
    var ssids: [String: String] = [:]             // Router-MAC -> echte SSID (gelernt)
    var hotspots: [String] = []                   // SSIDs, die als Handy-Hotspot erkannt wurden
    var sharedMACs: [String] = []                 // Router mit mehreren WLANs (z. B. Haupt + Gast)
    var lastSeen: [String: Double] = [:]          // Netzname -> zuletzt verbunden (Unix-Zeit)
    var bssids: [String: String] = [:]            // Sender-MAC (BSSID) -> zuletzt gesehene SSID
    var renamed: [String: String] = [:]           // alter WLAN-Name -> neuer (Netz umbenannt)

    init() {}

    /// Aktueller Name eines Netzes: folgt Umbenennungen (alt -> neu), Schleifen abgesichert.
    func currentName(_ name: String) -> String {
        var n = name, seen: Set<String> = [name]
        while let next = renamed[n], seen.insert(next).inserted { n = next }
        return n
    }

    /// SSID am Sender merken. Zeigt derselbe Sender (BSSID) plötzlich einen anderen Namen, wurde
    /// das Netz umbenannt (z. B. iPhone-Name geändert): alte Statistik läuft unter dem neuen
    /// Namen weiter. Ein zweites WLAN am selben Router (Gast) hat eine eigene BSSID.
    mutating func learn(ssid: String, bssid: String) {
        let b = bssid.lowercased()
        guard let old = bssids[b], old != ssid, currentName(old) != ssid else { bssids[b] = ssid; return }
        bssids[b] = ssid
        let from = currentName(old)
        renamed[from] = ssid
        renamed[ssid] = nil   // zurückbenannt: keine Schleife
        for (k, v) in renamed where v == from { renamed[k] = ssid }
        for (m, v) in ssids where v == from { ssids[m] = ssid }   // nur per Router-MAC gezählte Altdaten
        if hotspots.contains(from), !hotspots.contains(ssid) { hotspots.append(ssid) }
        if let t = lastSeen.removeValue(forKey: from) { lastSeen[ssid] = max(t, lastSeen[ssid] ?? 0) }
    }

    // Tolerantes Einlesen: fehlende Felder -> Standardwert (kein Datenverlust bei Updates).
    enum CodingKeys: String, CodingKey { case lastDown, lastUp, months, days, names, ssids, hotspots, sharedMACs, lastSeen, bssids, renamed }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastDown = try c.decodeIfPresent(UInt64.self, forKey: .lastDown)
        lastUp   = try c.decodeIfPresent(UInt64.self, forKey: .lastUp)
        months   = try c.decodeIfPresent([String: [String: Usage]].self, forKey: .months) ?? [:]
        days     = try c.decodeIfPresent([String: [String: Usage]].self, forKey: .days) ?? [:]
        names    = try c.decodeIfPresent([String: String].self, forKey: .names) ?? [:]
        ssids    = try c.decodeIfPresent([String: String].self, forKey: .ssids) ?? [:]
        hotspots = try c.decodeIfPresent([String].self, forKey: .hotspots) ?? []
        sharedMACs = try c.decodeIfPresent([String].self, forKey: .sharedMACs) ?? []
        lastSeen = try c.decodeIfPresent([String: Double].self, forKey: .lastSeen) ?? [:]
        bssids   = try c.decodeIfPresent([String: String].self, forKey: .bssids) ?? [:]
        renamed  = try c.decodeIfPresent([String: String].self, forKey: .renamed) ?? [:]
    }
}

// MARK: - Darstellung in der Menüleiste (in der Übersicht wählbar)
enum BarStyle: String, CaseIterable, Identifiable {
    case stats       // oben Name, unten Verbrauch (Standard)
    case iconStats   // WLAN-Symbol + Name + Verbrauch
    case iconValue   // WLAN-Symbol + Verbrauch
    case value       // nur der Verbrauch
    case icon        // nur das WLAN-Symbol

    var id: String { rawValue }
    var title: String {
        switch self {
        case .stats:     return L("Name + Verbrauch", "Name + usage")
        case .iconStats: return L("WLAN-Symbol + Name + Verbrauch", "Wi-Fi icon + name + usage")
        case .iconValue: return L("WLAN-Symbol + Verbrauch", "Wi-Fi icon + usage")
        case .value:     return L("Nur Verbrauch", "Usage only")
        case .icon:      return L("Nur WLAN-Symbol", "Wi-Fi icon only")
        }
    }
    static var current: BarStyle {
        get { UserDefaults.standard.string(forKey: "barStyle").flatMap(BarStyle.init) ?? .stats }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "barStyle") }
    }
}

// MARK: - Sprache + Einstellungen
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, de, en
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L("Wie das System", "Same as system")
        case .de:     return "Deutsch"
        case .en:     return "English"
        }
    }
}

/// Einstellungen (gespeichert in den UserDefaults). Änderungen zeichnen Menüleiste
/// und offene Fenster sofort neu.
final class Prefs: ObservableObject {
    static let shared = Prefs()
    var onChange: (() -> Void)?

    @Published var style = BarStyle.current {
        didSet { BarStyle.current = style; onChange?() }
    }
    @Published var language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .system {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "language"); onChange?() }
    }
    @Published var locationGranted = false   // vom AppController gesetzt
    /// Bei der Anmeldung automatisch starten (Standard: an).
    @Published var launchAtLogin = UserDefaults.standard.object(forKey: "launchAtLogin") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            if launchAtLogin { Autostart.enable() } else { Autostart.disable() }
        }
    }
    /// Eigene iPhones/iPads (gleiche Apple-ID) immer im Menü, auch mit ausgeschaltetem Hotspot.
    @Published var instantHotspot = UserDefaults.standard.object(forKey: "instantHotspot") as? Bool ?? true {
        didSet { UserDefaults.standard.set(instantHotspot, forKey: "instantHotspot"); onChange?() }
    }

    var isGerman: Bool {
        switch language {
        case .de: return true
        case .en: return false
        case .system: return Locale.preferredLanguages.first?.hasPrefix("de") ?? false
        }
    }
}

/// Text in der gewählten Sprache.
func L(_ de: String, _ en: String) -> String { Prefs.shared.isGerman ? de : en }

var unknownName: String { L("Unbekanntes WLAN", "Unknown Wi-Fi") }

/// Von den Fenstern aus erreichbare App-Aktionen (setzt der AppController).
enum Actions {
    static var openSettings: () -> Void = {}
    static var openLocationSettings: () -> Void = {}
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
        guard let d = try? Data(contentsOf: fileURL) else { return }   // erster Start: noch keine Datei
        guard let s = try? JSONDecoder().decode(Store.self, from: d) else {
            // Kaputt oder unbekanntes Format: beiseitelegen statt beim nächsten Speichern überschreiben
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"
            let keep = fileURL.deletingLastPathComponent().appendingPathComponent("usage.unlesbar-\(f.string(from: Date())).json")
            try? FileManager.default.moveItem(at: fileURL, to: keep)
            NSLog("Wifi Usage: usage.json nicht lesbar, gesichert als \(keep.lastPathComponent)")
            return
        }
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
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// WLAN-Schnittstelle (meist en0). static let: einmal ermittelt, threadsicher.
    static func wifiInterface() -> String { iface }
    private static let iface: String = {
        if let n = CWWiFiClient.shared().interface()?.interfaceName { return n }
        let lines = run("/usr/sbin/networksetup", ["-listallhardwareports"]).components(separatedBy: "\n")
        for (i, line) in lines.enumerated()
        where (line.contains("Hardware Port: Wi-Fi") || line.contains("Hardware Port: AirPort")) && i + 1 < lines.count {
            if let dev = lines[i + 1].components(separatedBy: " ").last, !dev.isEmpty { return dev }
        }
        return "en0"
    }()

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
        // nur echte IPv4-Adressen an arp geben (Gateway kommt vom DHCP des WLANs)
        guard gw.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil else { return nil }
        let out = run("/usr/sbin/arp", ["-n", gw])
        // Beispiel: "? (172.20.10.1) at 8e:12:aa:bb:cc:dd on en0 ifscope [ethernet]"
        guard let r = out.range(of: " at ") else { return nil }
        let rest = out[r.upperBound...]
        let mac = rest.split(separator: " ").first.map(String.init) ?? ""
        if mac.isEmpty || mac.contains("incomplete") || !mac.contains(":") { return nil }
        return mac
    }

    /// SSID über Kommandozeile (nur falls `sudo ipconfig setverbose 1` gesetzt ist).
    static func ssidCLI(_ iface: String) -> String? {
        let b = run("/usr/sbin/ipconfig", ["getsummary", iface])
        for line in b.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("SSID :") {
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

    /// Gespeicherte (bekannte) WLANs in der Reihenfolge der Systemeinstellungen.
    static func preferredNetworks(_ iface: String) -> [String] {
        let out = run("/usr/sbin/networksetup", ["-listpreferredwirelessnetworks", iface])
        return out.components(separatedBy: "\n").dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - WLAN über CoreWLAN
enum Wifi {
    static var iface: CWInterface? { CWWiFiClient.shared().interface() }
    static var isOn: Bool { iface?.powerOn() ?? false }

    /// Echte SSID (benötigt Ortungsdienste-Freigabe), sonst Kommandozeilen-Fallback.
    static func ssid() -> String? {
        if let s = iface?.ssid(), !s.isEmpty { return s }
        return Sys.ssidCLI(Sys.wifiInterface())
    }

    /// Signalstärke 0…1 für das Menüleisten-Symbol (nil = nicht verbunden).
    static func signal() -> Double? {
        guard let i = iface, i.powerOn() else { return nil }
        let rssi = i.rssiValue()
        guard rssi != 0 else { return nil }
        return level(rssi)
    }

    static func level(_ rssi: Int) -> Double {
        switch rssi {
        case (-60)...: return 1.0
        case (-70)...: return 0.67
        case (-80)...: return 0.34
        default:       return 0.1
        }
    }
}

// MARK: - Apples interne WLAN-Schnittstelle (CoreWiFi)
/// Dieselbe Schnittstelle, die Apples WLAN-Menü nutzt: verbindet mit gespeicherten Netzen über
/// deren Profil — ohne Passwort- oder Admin-Abfrage. Die öffentliche API (CoreWLAN) verlangt
/// dafür das Passwort, networksetup scheitert seit macOS 14. Privat und undokumentiert: Ändert
/// Apple sie, liefert joinKnown einen Fehler und das Menü zeigt „Fehlgeschlagen".
enum CoreWiFi {
    private typealias ObjFn = @convention(c) (AnyObject, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>?) -> AnyObject?
    private typealias BoolFn = @convention(c) (AnyObject, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool
    private typealias SetBoolFn = @convention(c) (AnyObject, Selector, Bool) -> Void

    private static let loaded = dlopen("/System/Library/PrivateFrameworks/CoreWiFi.framework/CoreWiFi", RTLD_NOW) != nil

    /// Pro Wechsel eine frische Verbindung zum WLAN-Dienst: Eine lange gehaltene wird nach
    /// Ruhezustand oder WLAN aus/an still ungültig, Aufträge laufen dann ins Leere.
    /// nil, wenn die interne Schnittstelle fehlt oder sich geändert hat (dann kein Absturz,
    /// sondern „Fehlgeschlagen").
    private static func makeInterface() -> NSObject? {
        guard loaded, let cls = NSClassFromString("CWFInterface") as? NSObject.Type,
              let cScan = NSClassFromString("CWFScanParameters") as? NSObject.Type,
              let cAssoc = NSClassFromString("CWFAssocParameters") as? NSObject.Type else { return nil }
        let i = cls.init()
        guard i.supports("activate", "knownNetworkProfilesWithProperties:", "performScanWithParameters:error:",
                         "associateWithParameters:error:"),
              cScan.init().supports("setCacheOnly:"),
              cAssoc.init().supports("setKnownNetworkProfile:", "setScanResult:") else { return nil }
        _ = i.perform(NSSelectorFromString("activate"))
        return i
    }

    private static func list(_ obj: Any?) -> [NSObject] {
        if let a = obj as? [NSObject] { return a }
        if let s = obj as? NSSet { return s.allObjects as? [NSObject] ?? [] }
        return []
    }
    private static func name(_ o: NSObject) -> String? { o.safeValue("networkName") as? String }

    /// Sicherheitsart aus dem von macOS gespeicherten Profil (z. B. "wpa2-personal",
    /// "wpa2-enterprise"), nil = kein Profil.
    static func profileSecurity(_ ssid: String) -> String? {
        guard let i = makeInterface() else { return nil }
        let profiles = list(i.perform(NSSelectorFromString("knownNetworkProfilesWithProperties:"), with: nil)?.takeUnretainedValue())
        return profiles.first(where: { name($0) == ssid }).flatMap(security(of:))
    }

    /// Sicherheitsart eines Profils oder Suchergebnisses („wpa2-personal" …), steht in dessen Beschreibung.
    private static func security(of o: NSObject) -> String? {
        let d = String(describing: o)
        guard let r = d.range(of: "security=[^,\\s]*", options: .regularExpression) else { return nil }
        return String(d[r].dropFirst("security=".count)).lowercased()
    }

    /// Gespeichertes Netz verbinden. nil = Auftrag angenommen, sonst Fehlertext.
    static func joinKnown(_ ssid: String, freshScan: Bool = false) -> String? {
        guard let i = makeInterface(),
              let cParams = NSClassFromString("CWFScanParameters") as? NSObject.Type,
              let cAssoc = NSClassFromString("CWFAssocParameters") as? NSObject.Type else {
            return "CoreWiFi nicht verfügbar"
        }
        // 1) gespeichertes Profil zum Namen
        let profiles = list(i.perform(NSSelectorFromString("knownNetworkProfilesWithProperties:"), with: nil)?.takeUnretainedValue())
        guard let profile = profiles.first(where: { name($0) == ssid }) else { return "Kein gespeichertes Profil" }
        // Evil Twin: Ist das gespeicherte Netz verschlüsselt, offene Sender gleichen Namens ignorieren
        // (sonst könnte ein fremdes offenes Netz mit demselben Namen den Verkehr mitlesen).
        let sec = security(of: profile) ?? ""
        let secured = !(sec.isEmpty || sec == "none" || sec == "open" || sec.hasPrefix("owe"))

        // 2) Suchergebnis zum Namen (stärkster Sender): erst aus dem System-Zwischenspeicher
        //    (sofort), nur wenn das Netz dort fehlt, frisch suchen (dauert einige Sekunden).
        var error: NSError?
        let scanSel = NSSelectorFromString("performScanWithParameters:error:")
        func scan(cacheOnly: Bool) -> NSObject? {
            let p = cParams.init()
            let cacheSel = NSSelectorFromString("setCacheOnly:")
            if cacheOnly, p.responds(to: cacheSel) {
                unsafeBitCast(p.method(for: cacheSel), to: SetBoolFn.self)(p, cacheSel, true)
            }
            let found = unsafeBitCast(i.method(for: scanSel), to: ObjFn.self)(i, scanSel, p, &error)
            return list(found).filter { name($0) == ssid && !(secured && ($0.safeValue("isOpen") as? Bool) == true) }
                .max { ($0.safeValue("RSSI") as? Int ?? -200) < ($1.safeValue("RSSI") as? Int ?? -200) }
        }
        guard let result = (freshScan ? nil : scan(cacheOnly: true)) ?? scan(cacheOnly: false) else {
            return error?.localizedDescription ?? "Netz nicht in Reichweite"
        }

        // 3) verbinden
        let params = cAssoc.init()
        _ = params.perform(NSSelectorFromString("setKnownNetworkProfile:"), with: profile)
        _ = params.perform(NSSelectorFromString("setScanResult:"), with: result)
        let assocSel = NSSelectorFromString("associateWithParameters:error:")
        let ok = unsafeBitCast(i.method(for: assocSel), to: BoolFn.self)(i, assocSel, params, &error)
        if i.responds(to: NSSelectorFromString("invalidate")) { _ = i.perform(NSSelectorFromString("invalidate")) }
        return ok ? nil : (error?.localizedDescription ?? "Verbinden abgelehnt")
    }
}

extension NSObject {
    /// value(forKey:) ohne Absturz: Private Apple-Objekte können Schlüssel mit einem Update verlieren.
    func safeValue(_ key: String) -> Any? { responds(to: NSSelectorFromString(key)) ? value(forKey: key) : nil }
    /// Gibt es alle diese Methoden? (vor Aufrufen privater Apple-Methoden prüfen)
    func supports(_ selectors: String...) -> Bool { selectors.allSatisfy { responds(to: NSSelectorFromString($0)) } }
}

// MARK: - Instant Hotspot (Apples interne Sharing-Schnittstelle)
/// Findet eigene iPhones/iPads (gleiche Apple-ID) per Bluetooth — auch mit ausgeschaltetem
/// Hotspot — und schaltet ihren Hotspot ein, wie „Persönlicher Hotspot" in Apples WLAN-Menü.
/// Privat und undokumentiert: Ändert Apple sie, findet die Suche einfach keine Geräte mehr.
final class RemoteHotspot: NSObject {
    struct Device {
        let name: String          // = Netzname des Hotspots
        let network: String?      // „LTE", „5G" …
        let object: NSObject      // für den Weckruf
        let seenAt: Date
    }
    static let shared = RemoteHotspot()
    var onChange: (() -> Void)?
    private(set) var devices: [String: Device] = [:]   // nur auf dem Hauptthread
    private var session: NSObject?

    private static let loaded = dlopen("/System/Library/PrivateFrameworks/Sharing.framework/Sharing", RTLD_NOW) != nil

    /// Suche starten (beim Öffnen des Menüs). Erste Treffer kommen nach Sekundenbruchteilen.
    func start() {
        guard session == nil, Self.loaded, let cls = NSClassFromString("SFRemoteHotspotSession") as? NSObject.Type else { return }
        let s = cls.init()
        guard s.supports("setDelegate:", "startBrowsing", "stopBrowsing",
                         "enableHotspotForDevice:withCompletionHandler:") else { return }
        s.setValue(self, forKey: "delegate")
        _ = s.perform(NSSelectorFromString("startBrowsing"))
        session = s
    }

    func stop() {
        _ = session?.perform(NSSelectorFromString("stopBrowsing"))
        session = nil
    }

    @objc(session:updatedFoundDevices:)
    func session(_ session: AnyObject, updatedFoundDevices list: AnyObject?) {
        let objs = (list as? [NSObject]) ?? ((list as? NSSet)?.allObjects as? [NSObject] ?? [])
        RunLoop.main.perform(inModes: [.common]) {
            self.devices = [:]   // jede Meldung ist die vollständige Liste
            for o in objs {
                guard let name = o.safeValue("deviceName") as? String, !name.isEmpty else { continue }
                self.devices[name] = Device(name: name, network: Self.networkName(o),
                                            object: o, seenAt: Date())
            }
            self.onChange?()
        }
    }

    /// Netzart, wie Apple sie selbst beschriftet („LTE", „5G" …) — steht in der Gerätebeschreibung;
    /// networkType selbst ist nur eine undokumentierte Zahl.
    private static func networkName(_ o: NSObject) -> String? {
        let d = String(describing: o)
        guard let r = d.range(of: "network type: [^,>]+", options: .regularExpression) else { return nil }
        let v = d[r].dropFirst("network type: ".count).trimmingCharacters(in: .whitespaces)
        return v.isEmpty || v.lowercased().contains("unknown") ? nil : v
    }

    /// Hotspot einschalten (blockiert bis zur Antwort, max. 15 s — nur aus dem Hintergrund
    /// aufrufen). Liefert Netzname und Passwort, das das iPhone dafür zurückgibt.
    static func enable(_ device: NSObject) -> (ssid: String?, password: String?)? {
        guard let s = shared.sessionForCall() else { return nil }
        let done = DispatchSemaphore(value: 0)
        var result: (String?, String?)?
        let cb: @convention(block) (AnyObject?, AnyObject?) -> Void = { a, b in
            result = (a as? String, b as? String)
            done.signal()
        }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Void
        let sel = NSSelectorFromString("enableHotspotForDevice:withCompletionHandler:")
        guard s.responds(to: sel) else { return nil }
        unsafeBitCast(s.method(for: sel), to: Fn.self)(s, sel, device, cb as AnyObject)
        return done.wait(timeout: .now() + 15) == .success ? result : nil
    }

    private func sessionForCall() -> NSObject? {
        if let s = session { return s }
        guard Self.loaded, let cls = NSClassFromString("SFRemoteHotspotSession") as? NSObject.Type else { return nil }
        return cls.init()
    }
}

// MARK: - WLAN-Zugangsdaten
/// Zugangsdaten aus dem Anmelde-Dialog: Passwort, bei Enterprise-Netzen (802.1X) zusätzlich
/// Benutzername. Nur für den einen Verbindungsversuch im Speicher — Wifi Usage speichert und liest
/// keine Passwörter; nach erfolgreicher Verbindung merkt sich macOS das Netz selbst.
struct WifiCredentials {
    var username: String?
    var password: String
}

// MARK: - Netz-Identität (Schlüssel + Anzeigename)
struct Net { let key: String; let name: String }

enum NetID {
    // Letzte Router-MAC je Verbindung (Gateway + eigene IP). `arp` liefert kurz nach
    // dem Verbinden oder nach Ablauf des Caches manchmal nichts — dann nicht auf einen
    // anderen Schlüssel ausweichen (das hat früher die Statistik zerstückelt).
    private static var sticky: (gw: String, ip: String, mac: String, ssid: String?)?

    /// iPhone-Hotspots vergeben immer 172.20.10.x, Android meist 192.168.43.1.
    static func isHotspotGateway(_ gw: String?) -> Bool {
        guard let gw = gw else { return false }
        return gw.hasPrefix("172.20.10.") || gw == "192.168.43.1"
    }

    /// Handy-Hotspot? Gelernt (Gateway) oder am Namen erkennbar.
    static func isHotspot(_ ssid: String) -> Bool {
        if Storage.shared.store.hotspots.contains(ssid) { return true }
        let l = ssid.lowercased()
        return l.contains("iphone") || l.contains("ipad") || l.contains("hotspot") || l.contains("android")
    }

    static func current() -> Net? {
        let iface = Sys.wifiInterface()
        guard let ip = Sys.ifaceIP(iface) else { sticky = nil; return nil }   // nicht verbunden

        let gw = Sys.gateway()
        let same = sticky.map { $0.gw == gw && $0.ip == ip } ?? false   // noch dieselbe Verbindung?
        var mac = gw.flatMap { Sys.routerMAC($0) }
        if mac == nil, same { mac = sticky?.mac }

        // SSID; fehlt sie kurz (z. B. während einer Netzsuche), gilt die der laufenden Verbindung.
        let ssid = Wifi.ssid() ?? (same ? sticky?.ssid : nil)
        if let m = mac, let g = gw { sticky = (g, ip, m, ssid) }

        let store = Storage.shared
        if let ssid = ssid {
            if let b = Wifi.iface?.bssid(), !b.isEmpty { store.store.learn(ssid: ssid, bssid: b) }
            if let m = mac {
                // MAC -> SSID lernen, nur einmal (alte, nur per MAC gezählte Daten wandern sonst mit).
                // Zweites WLAN am selben Router (Haupt + Gast): Router als „geteilt" merken.
                if let known = store.store.ssids[m] {
                    if known != ssid, !store.store.sharedMACs.contains(m) { store.store.sharedMACs.append(m) }
                } else {
                    store.store.ssids[m] = ssid
                }
            }
            if isHotspotGateway(gw), !store.store.hotspots.contains(ssid) { store.store.hotspots.append(ssid) }
            return Net(key: SSID_PREFIX + ssid, name: ssid)
        }
        if let m = mac {
            // Bei geteilten Routern ist ohne SSID nicht klar, welches WLAN es ist -> nicht raten.
            if store.store.sharedMACs.contains(m) { return Net(key: UNKNOWN_KEY, name: unknownName) }
            if let ssid = store.store.ssids[m] { return Net(key: SSID_PREFIX + ssid, name: ssid) }
            let name: String
            if let gw = gw, gw.hasPrefix("172.20.10.") { name = "iPhone-Hotspot" }
            else if gw == "192.168.43.1" { name = "Android-Hotspot" }
            else { name = "WLAN ·" + m.split(separator: ":").suffix(2).joined(separator: ":") }
            return Net(key: m, name: name)
        }
        return Net(key: UNKNOWN_KEY, name: unknownName)
    }
}

// MARK: - Zähl-Logik
struct NetUsage: Identifiable {
    let name: String
    let usage: Usage
    var id: String { name }
}

enum Meter {
    /// Netz der letzten Messung — Menüleiste und Menü zeigen genau dieses Netz.
    static var currentNet: Net?

    static func monthKey(_ date: Date = Date()) -> String { dateKey(date, "yyyy-MM") }
    static func dayKey(_ date: Date = Date()) -> String { dateKey(date, "yyyy-MM-dd") }
    private static func dateKey(_ date: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f.string(from: date)
    }

    static func sample() {
        let s = Storage.shared
        let iface = Sys.wifiInterface()
        let net = NetID.current()
        currentNet = net
        if let net = net { s.store.lastSeen[net.name] = Date().timeIntervalSince1970 }
        guard let cur = Sys.counters(iface) else { s.save(); return }
        let key = monthKey(), day = dayKey()

        if let ld = s.store.lastDown, let lu = s.store.lastUp {
            let dDown: UInt64 = cur.down >= ld ? cur.down - ld : cur.down
            let dUp:   UInt64 = cur.up   >= lu ? cur.up   - lu : cur.up
            if let net = net, (dDown > 0 || dUp > 0) {
                var month = s.store.months[key] ?? [:]
                var u = month[net.key] ?? Usage()
                u.down &+= dDown; u.up &+= dUp
                month[net.key] = u
                s.store.months[key] = month
                var d = s.store.days[day] ?? [:]
                var du = d[net.key] ?? Usage()
                du.down &+= dDown; du.up &+= dUp
                d[net.key] = du
                s.store.days[day] = d
                if !net.key.hasPrefix(SSID_PREFIX) { s.store.names[net.key] = net.name }
            }
        }
        s.store.lastDown = cur.down
        s.store.lastUp = cur.up
        s.save()
    }

    /// Anzeigename eines Schlüssels: echte SSID > gelernte SSID der Router-MAC > Ersatzname.
    static func displayName(for key: String) -> String {
        let st = Storage.shared.store
        if key.hasPrefix(SSID_PREFIX) { return st.currentName(String(key.dropFirst(SSID_PREFIX.count))) }
        if let ssid = st.ssids[key] { return st.currentName(ssid) }
        if key == UNKNOWN_KEY || key == "wlan" { return unknownName }
        let n = st.names[key] ?? key
        return n == "WLAN" ? unknownName : n
    }

    /// Verbrauch eines Monats, zusammengefasst nach Anzeigename (größter zuerst).
    static func grouped(month: String) -> [NetUsage] {
        grouped(Storage.shared.store.months[month] ?? [:])
    }
    static func grouped(day: String) -> [NetUsage] {
        grouped(Storage.shared.store.days[day] ?? [:])
    }
    static func grouped(_ entries: [String: Usage]) -> [NetUsage] {
        var g: [String: Usage] = [:]
        for (k, u) in entries {
            let n = displayName(for: k)
            var x = g[n] ?? Usage()
            x.down &+= u.down; x.up &+= u.up
            g[n] = x
        }
        return g.map { NetUsage(name: $0.key, usage: $0.value) }.sorted { $0.usage.total > $1.usage.total }
    }

    static func usage(month: String, name: String) -> Usage {
        grouped(month: month).first { $0.name == name }?.usage ?? Usage()
    }

    /// Verbrauch eines Zeitraums (Monat oder ganzes Jahr), nach Anzeigename zusammengefasst.
    static func grouped(period: Period) -> [NetUsage] {
        var all: [String: Usage] = [:]
        for (m, entries) in Storage.shared.store.months where period.contains(monthKey: m) {
            for (k, u) in entries {
                var x = all[k] ?? Usage()
                x.down &+= u.down; x.up &+= u.up
                all[k] = x
            }
        }
        return grouped(all)
    }
    static func usage(period: Period, name: String) -> Usage {
        grouped(period: period).first { $0.name == name }?.usage ?? Usage()
    }
}

/// Zeitraum der Übersicht: ein Monat ("2026-10") oder ein Jahr ("2026").
struct Period: Equatable {
    let key: String
    var isYear: Bool { !key.contains("-") }
    var title: String { isYear ? key : prettyMonth(key) }
    func contains(monthKey m: String) -> Bool { isYear ? m.hasPrefix(key + "-") : m == key }
    func contains(dayKey d: String) -> Bool { d.hasPrefix(key + "-") }
    var hasData: Bool { Storage.shared.store.months.keys.contains { contains(monthKey: $0) } }

    /// Vormonat bzw. Vorjahr
    var previous: Period {
        if isYear { return Period(key: String((Int(key) ?? 0) - 1)) }
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 2 else { return self }
        let (y, m) = p[1] == 1 ? (p[0] - 1, 12) : (p[0], p[1] - 1)
        return Period(key: String(format: "%04d-%02d", y, m))
    }
}

// MARK: - Dialog-Symbol
/// Blaues WLAN-Symbol auf transparentem Grund (wie das App-Icon) für alle Dialoge.
let wifiAlertIcon: NSImage = {
    let size: CGFloat = 64
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let cfg = NSImage.SymbolConfiguration(pointSize: 44, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1)]))
    if let s = NSImage(systemSymbolName: "wifi", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let scale = min(size * 0.8 / s.size.width, size * 0.8 / s.size.height)
        let w = s.size.width * scale, h = s.size.height * scale
        s.draw(in: NSRect(x: (size - w) / 2, y: (size - h) / 2, width: w, height: h))
    }
    img.unlockFocus()
    return img
}()

// MARK: - Formatierung
func gb(_ bytes: UInt64) -> String { String(format: "%.2f GB", Double(bytes) / GIB) }
func gbValue(_ bytes: UInt64) -> Double { Double(bytes) / GIB }

let MONTHS_DE = ["Januar","Februar","März","April","Mai","Juni",
                 "Juli","August","September","Oktober","November","Dezember"]
let MONTHS_EN = ["January","February","March","April","May","June",
                 "July","August","September","October","November","December"]

/// "2026-10" -> "Oktober 2026" (short: "Okt 26")
func prettyMonth(_ key: String, short: Bool = false) -> String {
    let p = key.split(separator: "-")
    guard p.count == 2, let m = Int(p[1]), m >= 1, m <= 12 else { return key }
    let name = (Prefs.shared.isGerman ? MONTHS_DE : MONTHS_EN)[m-1]
    return short ? "\(name.prefix(3)) \(p[0].suffix(2))" : "\(name) \(p[0])"
}

func sum(_ list: [NetUsage]) -> Usage {
    list.reduce(into: Usage()) { $0.down &+= $1.usage.down; $0.up &+= $1.usage.up }
}

// MARK: - Menüleisten-App
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate, CLLocationManagerDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let location = CLLocationManager()
    var timer: Timer?
    var inRange: [String: Seen] = [:]  // SSID -> Ergebnis der letzten Suche
    var scanning = false
    weak var openMenu: NSMenu?         // gerade offenes Menü
    var showOthers = false             // „Andere Netzwerke" aufgeklappt?
    weak var panel: WifiPanelView?     // WLAN-Bereich: einziger Teil, der sich im offenen Menü live ändert
    var joining: String?               // gerade im Verbindungsaufbau
    var joinGeneration = 0             // nur der letzte Verbindungsversuch zählt
    var joinAnimation: Timer?          // lässt die WLAN-Balken in der Menüleiste laufen
    var joinFrame = 0
    var failed: String?                // kurz „Fehlgeschlagen" am Netz statt Popup
    var failedReason = ""              // was beim Netz steht („Fehlgeschlagen" / „Nicht in Reichweite")
    var askAgain: Set<String> = []     // macOS-Profil hat nicht gereicht -> beim nächsten Klick nach dem Passwort fragen
    var powerTarget: Bool?             // Schalter sofort umlegen, bevor das System nachzieht
    var knownNetworks: Set<String> = []   // gespeicherte Netze (im Hintergrund aktualisiert)
    let pathMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    var wifiPathOK = true              // hat das WLAN einen Weg nach draußen (Gateway/Route)?
    /// Mit einem WLAN verbunden, aber ohne Ausgang (kein Gateway / keine Route ins Internet).
    var noInternet: Bool { Meter.currentNet != nil && joining == nil && !wifiPathOK }
    var autoClose: Timer?              // schließt das Menü nach einer Aktion bei Inaktivität
    var overviewWindow: NSWindow?
    var settingsWindow: NSWindow?
    var coffeeWindow: NSWindow?
    let overview = OverviewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(); menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageOnly

        installEditMenu()
        Autostart.setup()
        Log.prune()   // alte Log-Einträge weg, danach täglich
        let daily = Timer(timeInterval: 86_400, repeats: true) { _ in Log.prune() }
        RunLoop.main.add(daily, forMode: .common)
        RemoteHotspot.shared.onChange = { [weak self] in if self?.openMenu != nil { self?.updatePanel() } }
        Prefs.shared.onChange = { [weak self] in self?.prefsChanged() }
        Actions.openSettings = { [weak self] in self?.openSettings() }
        Actions.openLocationSettings = { [weak self] in self?.openLocationSettings() }

        // Ortungsdienste: nur nötig, damit macOS den WLAN-Namen herausgibt.
        location.delegate = self
        Prefs.shared.locationGranted = locationGranted
        NSLog("Wifi Usage: Start, Ortungsstatus \(location.authorizationStatus.rawValue), SSID \(Wifi.iface?.ssid() == nil ? "nicht lesbar" : "lesbar")")
        if location.authorizationStatus == .notDetermined {
            NSApp.activate(ignoringOtherApps: true)
            location.requestWhenInUseAuthorization()
        }

        // Passiv: macOS meldet, ob das WLAN eine nutzbare Route hat — ohne eigenen Netzverkehr.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.wifiPathOK = path.status == .satisfied
                self.updateTitle()
                if self.openMenu != nil { self.updatePanel() }
            }
        }
        pathMonitor.start(queue: DispatchQueue.global(qos: .utility))

        refresh()
        DispatchQueue.global(qos: .utility).async {   // bekannte Netze vorab laden (Menü öffnet dann sofort)
            let known = Set(Sys.preferredNetworks(Sys.wifiInterface()))
            DispatchQueue.main.async { self.knownNetworks = known }
        }
        scanAsync()
        timer = Timer.scheduledTimer(withTimeInterval: SAMPLE_INTERVAL, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer!, forMode: .common)

        // Beim allerersten Start einmal das Coffee-Fenster zeigen.
        if !UserDefaults.standard.bool(forKey: "coffeeSeen") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.openCoffee() }
        }
    }

    /// Unsichtbares Hauptmenü mit „Bearbeiten“: Eine Menüleisten-App hat keine eigene Menüleiste,
    /// ohne dieses Menü laufen ⌘V/⌘C/⌘X/⌘A/⌘Z in Textfeldern (Passwort-Dialog, Einstellungen) ins Leere.
    func installEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Bearbeiten")
        edit.addItem(withTitle: "Widerrufen", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Wiederholen", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Ausschneiden", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Einfügen", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Alles auswählen", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        NSLog("Wifi Usage: Ortungsstatus \(manager.authorizationStatus.rawValue), SSID \(Wifi.iface?.ssid() == nil ? "nicht lesbar" : "lesbar")")
        Prefs.shared.locationGranted = locationGranted
        refresh(); scanAsync()
    }

    func prefsChanged() {
        updateTitle()
        overview.reload()
        overviewWindow?.title = L("Wifi Usage – Übersicht", "Wifi Usage – Overview")
        settingsWindow?.title = L("Einstellungen", "Settings")
    }

    var locationGranted: Bool {
        let s = location.authorizationStatus
        return s == .authorizedAlways || s == .authorized
    }

    func updateTitle() {
        let net = Meter.currentNet
        let topText = net?.name ?? (Wifi.isOn ? L("kein WLAN", "no Wi-Fi") : L("WLAN aus", "Wi-Fi off"))
        var bottomText = "–"
        if let net = net {
            bottomText = gb(Meter.usage(month: Meter.monthKey(), name: net.name).total)
        }
        // Während des Verbindens laufen die Balken (0 → 1 → 2 → 3), sonst echte Signalstärke.
        let signal: Double? = joining != nil ? Double(joinFrame % 4) / 3
            : net == nil ? nil : (Wifi.signal() ?? 1.0)
        statusItem.button?.image = Self.render(style: BarStyle.current,
                                               signal: signal,
                                               top: topText, bottom: bottomText,
                                               noInternet: noInternet,
                                               // mit einem Hotspot verbunden: Ketten-Symbol wie bei Apple
                                               hotspot: joining == nil && net.map { NetID.isHotspot($0.name) } == true)
        statusItem.button?.toolTip = net.map { "\($0.name): \(bottomText) " + L("diesen Monat", "this month")
            + (noInternet ? " — " + L("keine Internetverbindung", "no internet connection") : "") }
    }

    // Stats-Stil: oben dünn der Name, unten die GB; je nach Stil mit/ohne WLAN-Symbol.
    /// „WLAN-Symbol + Verbrauch": Zahl kräftig, „GB" klein und dünn auf derselben Grundlinie,
    /// rechts daneben Apples WLAN-Symbol mit Signalstärke.
    /// Apples WLAN-Symbol: Balken = Signal, Ausrufezeichen = verbunden ohne Internet, durchgestrichen = kein WLAN.
    static func wifiSymbol(signal: Double?, noInternet: Bool, hotspot: Bool = false) -> NSImage? {
        if noInternet { return NSImage(systemSymbolName: "wifi.exclamationmark", accessibilityDescription: nil) }
        if hotspot, signal != nil { return NSImage(systemSymbolName: "personalhotspot", accessibilityDescription: nil) }
        return signal.flatMap { NSImage(systemSymbolName: "wifi", variableValue: $0, accessibilityDescription: nil) }
            ?? NSImage(systemSymbolName: "wifi.slash", accessibilityDescription: nil)
    }

    static func renderCompact(signal: Double?, bottom: String, noInternet: Bool = false, hotspot: Bool = false) -> NSImage {
        let value = Double(bottom.split(separator: " ").first ?? "").map { String(format: "%.1f", $0) } ?? "–"
        let numFont  = NSFont.systemFont(ofSize: 11, weight: .semibold)   // wie die Werte im Stats-Stil
        let unitFont = NSFont.systemFont(ofSize: 8, weight: .regular)
        let num  = NSAttributedString(string: value, attributes: [.font: numFont, .foregroundColor: NSColor.black, .kern: -0.1])
        let unit = NSAttributedString(string: value == "–" ? "" : "GB",
                                      attributes: [.font: unitFont, .foregroundColor: NSColor.black, .kern: 0.2])
        let icon = wifiSymbol(signal: signal, noInternet: noInternet, hotspot: hotspot)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        let ns = num.size(), us = unit.size(), iconSize = icon?.size ?? .zero

        let gapUnit: CGFloat = 1, gapIcon: CGFloat = 3   // eng: Wert und Symbol als eine Einheit
        let w = ceil(2 + ns.width + gapUnit + us.width + gapIcon + iconSize.width + 2)
        let h = max(NSStatusBar.system.thickness, 22)
        // Das Symbol steht wie ein Buchstabe auf der Grundlinie (sein Punkt auf Höhe der Zahl-Unterkante);
        // die ganze Gruppe (Grundlinie bis Symbol-Oberkante) sitzt mittig in der Leiste.
        // SF-Symbole haben oben/unten ca. 8 % unsichtbaren Rand -> Tinte statt Bildrahmen ausrichten.
        let inset = iconSize.height * 0.08
        let inkHeight = iconSize.height - 2 * inset
        let baseline = round((h - max(inkHeight, numFont.capHeight)) / 2 * 2) / 2

        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        num.draw(at: NSPoint(x: 2, y: baseline + numFont.descender))
        unit.draw(at: NSPoint(x: 2 + ns.width + gapUnit, y: baseline + unitFont.descender))
        icon?.draw(in: NSRect(x: w - 2 - iconSize.width, y: baseline - inset,
                              width: iconSize.width, height: iconSize.height))
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    static func render(style requested: BarStyle, signal: Double?, top: String, bottom: String,
                       noInternet: Bool = false, hotspot: Bool = false) -> NSImage {
        // Ohne Internet immer ein Symbol zeigen, auch in den Stilen ohne WLAN-Symbol.
        let style: BarStyle = !noInternet ? requested
            : requested == .stats ? .iconStats : requested == .value ? .iconValue : requested
        if style == .iconValue {
            return renderCompact(signal: signal, bottom: bottom, noInternet: noInternet, hotspot: hotspot)
        }
        let topFont = NSFont.systemFont(ofSize: 7, weight: .light)      // Netz-Name (obere Zeile)
        let botFont = NSFont.systemFont(ofSize: 11, weight: .semibold)  // GB-Wert (untere Zeile)
        // Template-Bild: Farbe egal, macOS tönt es passend zur Menüleiste (Light/Dark).
        let topColor = NSColor.black.withAlphaComponent(0.6)
        let botColor = NSColor.black
        let topStr = NSAttributedString(string: top, attributes: [.font: topFont, .foregroundColor: topColor])
        let botStr = NSAttributedString(string: bottom, attributes: [.font: botFont, .foregroundColor: botColor])
        let ts = topStr.size(), bs = botStr.size()

        var icon: NSImage?
        if style == .iconStats || style == .iconValue || style == .icon {
            let cfg = NSImage.SymbolConfiguration(pointSize: style == .iconStats ? 13 : 14, weight: .regular)
            icon = wifiSymbol(signal: signal, noInternet: noInternet, hotspot: hotspot)?.withSymbolConfiguration(cfg)
        }
        let iconSize = icon?.size ?? .zero

        let textW: CGFloat
        switch style {
        case .stats, .iconStats: textW = ceil(max(ts.width, bs.width))
        case .value, .iconValue: textW = ceil(bs.width)
        case .icon:              textW = 0
        }
        let textX = icon == nil ? 4 : 2 + iconSize.width + (textW > 0 ? (style == .iconValue ? 5 : 4) : 2)
        let w = textX + textW + (textW > 0 ? 4 : 0)
        let h = max(NSStatusBar.system.thickness, 22)

        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        icon?.draw(in: NSRect(x: 2, y: (h - iconSize.height) / 2, width: iconSize.width, height: iconSize.height))
        switch style {
        case .stats, .iconStats:
            // unten: GB, oben darüber: Netzname
            botStr.draw(at: NSPoint(x: textX + (textW - bs.width) / 2, y: 0))
            topStr.draw(at: NSPoint(x: textX + (textW - ts.width) / 2, y: h - ts.height + 1))
        case .value, .iconValue:
            botStr.draw(at: NSPoint(x: textX, y: (h - bs.height) / 2))
        case .icon:
            break
        }
        img.unlockFocus()
        img.isTemplate = true   // immer adaptiv, folgt der Menüleiste (Light/Dark)
        return img
    }

    // MARK: Menü — im Stil des macOS-WLAN-Menüs
    func menuNeedsUpdate(_ menu: NSMenu) {
        // Sofort aus dem Gemerkten aufbauen (letzte Messung, letzte Netzsuche) — keine
        // Systembefehle beim Öffnen; die Suche läuft im Hintergrund und aktualisiert live.
        build(menu)
        scanAsync()
        if Prefs.shared.instantHotspot { RemoteHotspot.shared.start() }   // eigene iPhones per Bluetooth
    }
    func menuWillOpen(_ menu: NSMenu) { openMenu = menu }
    func menuDidClose(_ menu: NSMenu) {
        openMenu = nil
        autoClose?.invalidate(); autoClose = nil
        RemoteHotspot.shared.stop()
    }

    /// Nach einer Aktion (WLAN wechseln, ein/aus) bleibt das Menü offen und schließt sich erst
    /// nach 5 s ohne Aktivität. Jede Mausbewegung über eine Zeile startet die Frist neu.
    func armAutoClose() {
        guard openMenu != nil else { return }
        autoClose?.invalidate()
        let t = Timer(timeInterval: 5, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.joining != nil { self.armAutoClose() } else { self.openMenu?.cancelTracking() }
        }
        RunLoop.main.add(t, forMode: .common)
        autoClose = t
    }
    func noteActivity() { if autoClose != nil { armAutoClose() } }

    func build(_ menu: NSMenu) {
        menu.removeAllItems()

        // WLAN-Bereich (Schalter, Hotspot, Bekannte, Andere) als ein einziger Eintrag:
        // Er zeichnet sich bei Änderungen selbst neu, das offene Menü wird nie umgebaut
        // (Hinzufügen/Entfernen von Einträgen bei offenem Menü hinterlässt sonst Geisterzeilen).
        let p = WifiPanelView()
        p.onPower = { [weak self] on in self?.setPower(on) }
        p.onSelect = { [weak self] row in self?.select(row) }
        p.onToggleOthers = { [weak self] open in
            self?.showOthers = open
            if open { self?.scanAsync() }
        }
        p.onActivity = { [weak self] in self?.noteActivity() }
        menu.addItem(viewItem(p))
        panel = p
        updatePanel()

        menu.addItem(.separator())
        menu.addItem(action(L("WLAN-Einstellungen …", "Wi-Fi Settings …"), #selector(openWifiSettings)))
        if !locationGranted {
            menu.addItem(action(L("WLAN-Namen anzeigen: Ortungsdienste erlauben …",
                                  "Show Wi-Fi names: allow Location Services …"), #selector(openLocationSettings)))
        }
        menu.addItem(.separator())
        // unten: Übersicht links, Zahnrad (Einstellungen) rechts
        let footer = FooterRowView(title: L("Übersicht & Statistik …", "Overview & Statistics …"))
        footer.onClick = { [weak self] in self?.openOverview() }
        footer.onGear = { [weak self] in self?.openSettings() }
        menu.addItem(viewItem(footer))
    }

    /// Inhalt des WLAN-Bereichs aus dem aktuellen Zustand berechnen und ins Panel übernehmen.
    func updatePanel() {
        guard let panel = panel else { return }
        var c = PanelContent(wifiOn: powerTarget ?? Wifi.isOn, othersExpanded: showOthers)
        c.scanning = scanning
        if c.wifiOn {
            let net = Meter.currentNet
            let month = Meter.monthKey()
            let known = knownNetworks
            // verbundenes zuerst, dann bekannte in Reichweite (stärkstes Signal zuerst)
            var names = known.filter { inRange[$0] != nil }.sorted { inRange[$0]!.rssi > inRange[$1]!.rssi }
            // Eigene iPhones/iPads immer, auch mit ausgeschaltetem Hotspot (Klick weckt ihn auf)
            let phones = Prefs.shared.instantHotspot ? RemoteHotspot.shared.devices : [:]
            let phoneNames = phones.keys.sorted()
            names.removeAll { phones[$0] != nil }
            names.insert(contentsOf: phoneNames, at: 0)
            if let cur = net?.name { names.removeAll { $0 == cur }; names.insert(cur, at: 0) }

            func row(_ ssid: String, known: Bool) -> RowInfo {
                let phone = phones[ssid]
                let connected = ssid == net?.name
                let u = Meter.usage(month: month, name: ssid)
                let rssi = inRange[ssid]?.rssi ?? (connected ? Wifi.iface?.rssiValue() : nil)
                let detail = ssid == joining ? nil   // Warte-Kreis statt Text, wie bei Apple
                    : ssid == failed ? failedReason
                    : (connected || u.total > 0) && known ? gb(u.total) : nil
                let offline = connected && noInternet
                let phoneInfo = phone.map { p in
                    // kein Akku: der Wert vom iPhone ist grob/veraltet (zeigte immer „75 %“), das wäre irreführend
                    [L("Hotspot", "Hotspot"), p.network].compactMap { $0 }.joined(separator: " · ")
                }
                return RowInfo(ssid: ssid, detail: detail,
                               symbol: offline ? "wifi.exclamationmark" : phone != nil || NetID.isHotspot(ssid) ? "personalhotspot" : "wifi",
                               signal: rssi.map { Wifi.level($0) }, connected: connected,
                               secure: inRange[ssid]?.secure ?? true, known: known,
                               tooltip: u.total > 0 ? "↓ \(gb(u.down))   ↑ \(gb(u.up)) " + L("diesen Monat", "this month") : nil,
                               joining: ssid == joining,
                               subtitle: offline ? L("Keine Internetverbindung", "No internet connection")
                                   : phoneInfo)
            }
            // Eine Liste: verbundenes, eigene iPhones (Instant Hotspot), dann in Reichweite
            // (stärkstes Signal) — Hotspots mit Ketten-Symbol.
            c.known = names.map { row($0, known: true) }
            if names.isEmpty {
                c.knownHint = scanning ? L("Suche nach Netzwerken …", "Searching for networks …")
                                       : L("Keine bekannten Netzwerke in Reichweite", "No known networks in range")
            }
            c.others = inRange.filter { !known.contains($0.key) && $0.key != net?.name && phones[$0.key] == nil }
                .sorted { $0.value.rssi > $1.value.rssi }.map { row($0.key, known: false) }
            if c.others.isEmpty {
                c.othersHint = !locationGranted ? L("Ortungsdienste nötig, um Netze zu finden", "Location Services needed to find networks")
                    : scanning ? L("Suche nach Netzwerken …", "Searching for networks …")
                    : L("Keine weiteren Netzwerke", "No other networks")
            }
        }
        panel.update(c)
    }

    func viewItem(_ v: NSView) -> NSMenuItem {
        let it = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        it.view = v
        return it
    }

    func sectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        return info(title, header: true)
    }

    func info(_ title: String, header: Bool = false) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = !header   // Überschriften grau, Werte normal lesbar
        return it
    }

    func action(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = self
        return it
    }

    // Netzsuche im Hintergrund (liefert SSIDs nur mit Ortungsdienste-Freigabe).
    func scanAsync(retries: Int = 0) {
        // nicht während eines Wechsels: die Suche blockiert sonst den WLAN-Chip für den Wechsel
        guard !scanning, joining == nil, locationGranted, let iface = Wifi.iface, iface.powerOn() else { return }
        scanning = true
        if openMenu != nil { updatePanel() }   // Warte-Kreis „sucht" oben im Menü
        DispatchQueue.global(qos: .utility).async {
            let known = Set(Sys.preferredNetworks(iface.interfaceName ?? Sys.wifiInterface()))
            // Nur die frische Suche: Der System-Zwischenspeicher enthält auch Netze, die längst außer
            // Reichweite sind. Kurzes Flackern schwacher Netze fängt das 30-s-Behalten unten ab.
            let fresh = (try? iface.scanForNetworks(withSSID: nil)) ?? []
            let nets = fresh.isEmpty ? (iface.cachedScanResults() ?? []) : fresh
            var found: [String: Seen] = [:]
            for n in nets {
                guard let s = n.ssid, !s.isEmpty else { continue }
                if let old = found[s], old.rssi >= n.rssiValue { continue }
                found[s] = Seen(rssi: n.rssiValue, secure: n.needsCredentials, network: n, seenAt: Date(),
                                enterprise: n.isEnterprise)
            }
            RunLoop.main.perform(inModes: [.common]) {   // auch während das Menü offen ist
                // Netze aus früheren Durchläufen kurz (30 s) behalten, damit die Liste nicht flackert,
                // aber nichts Veraltetes stehen bleibt.
                let keep = self.inRange.filter { found[$0.key] == nil && Date().timeIntervalSince($0.value.seenAt) < 30 }
                self.inRange = found.merging(keep) { new, _ in new }
                self.knownNetworks = known
                self.scanning = false
                if self.openMenu != nil { self.updatePanel() }
                // direkt nach dem Einschalten liefert die Suche oft noch nichts -> kurz nachfassen
                if found.isEmpty, retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.scanAsync(retries: retries - 1) }
                }
            }
        }
    }

    /// Klick auf ein Netz: verbundenes -> Übersicht, gespeichertes -> über Apples Profil verbinden
    /// (Menü bleibt offen), fremdes -> verbinden, bei Passwortschutz vorher Passwort abfragen.
    func select(_ row: RowInfo) {
        let ssid = row.ssid
        if row.connected { openMenu?.cancelTracking(); openOverview(); return }
        if Prefs.shared.instantHotspot, let phone = RemoteHotspot.shared.devices[ssid] { joinHotspot(phone); return }
        // Gespeichertes Netz (offen, WPA oder Enterprise): wie Apples WLAN-Menü über das von macOS
        // gespeicherte Profil — das Passwort holt sich macOS selbst, Wifi Usage braucht keins.
        if row.known && !askAgain.contains(ssid) {
            connect(ssid, attempt: {
                let failure = CoreWiFi.joinKnown(ssid)
                if let f = failure { NSLog("Wifi Usage: Verbinden mit \(ssid) fehlgeschlagen: \(f)") }
                return failure
            }, retry: {
                NSLog("Wifi Usage: \(ssid) nicht verbunden, neuer Versuch mit frischer Suche")
                return CoreWiFi.joinKnown(ssid, freshScan: true)
            }, completion: { [weak self] joined, message in
                guard let self = self, !joined, message != "Netz nicht in Reichweite" else { return }
                // Profil hat nicht gereicht (z. B. Passwort geändert): offenes Netz direkt versuchen,
                // geschütztes beim nächsten Klick nach dem Passwort fragen.
                self.joinWithCredentials(row, interactive: false)
            })
            return
        }
        joinWithCredentials(row, interactive: true)
    }

    /// Eigenes iPhone: Hotspot per Bluetooth einschalten (wie Apples „Persönlicher Hotspot"),
    /// gezielt suchen — ein frisch geweckter Hotspot taucht erst nach ein paar Sekunden auf —
    /// und verbinden: bekanntes Netz über Apples Profil, sonst mit dem Passwort vom iPhone.
    func joinHotspot(_ phone: RemoteHotspot.Device) {
        let ssid = phone.name
        let known = knownNetworks.contains(ssid)
        connect(ssid, attempt: {
            let reply = RemoteHotspot.enable(phone.object)
            NSLog("Wifi Usage: Hotspot \(ssid) " + (reply == nil ? "nicht geweckt" : "geweckt"))
            guard let iface = Wifi.iface else { return "WLAN nicht verfügbar" }
            // Bis zu 25 s gezielt suchen. Eine Suche scheitert sofort, solange der WLAN-Chip noch
            // mit einer anderen beschäftigt ist (z. B. der Menü-Suche) — dann kurz warten.
            let started = Date()
            var tries = 0
            while Date().timeIntervalSince(started) < 25 {
                if Wifi.iface?.ssid() == ssid { return nil }   // macOS hat schon selbst verbunden
                tries += 1
                do {
                    let found = try iface.scanForNetworks(withName: ssid, includeHidden: true)
                    // iPhone-Hotspots sind immer verschlüsselt: offenes Netz gleichen Namens = Fälschung
                    if let n = found.filter(\.needsCredentials).max(by: { $0.rssiValue < $1.rssiValue }) {
                        NSLog("Wifi Usage: Hotspot \(ssid) nach \(tries) Suchen gefunden")
                        if known {
                            let failure = CoreWiFi.joinKnown(ssid)
                            if failure == nil { return nil }
                            NSLog("Wifi Usage: Profil für \(ssid) abgelehnt (\(failure!)), versuche mit Passwort vom iPhone")
                        }
                        do { try iface.associate(to: n, password: reply?.password); return nil }
                        catch { return error.localizedDescription }
                    }
                    Thread.sleep(forTimeInterval: 0.3)   // noch nicht da: gleich nochmal
                } catch {
                    NSLog("Wifi Usage: Suche nach \(ssid): \(error.localizedDescription)")
                    Thread.sleep(forTimeInterval: 1)   // WLAN-Chip belegt
                }
            }
            return "Netz nicht in Reichweite"
        }, retry: known ? { CoreWiFi.joinKnown(ssid, freshScan: true) } : nil)
    }

    /// Verbinden über CoreWLAN; geschützt -> Passwort abfragen. Was das Netz verlangt, im
    /// Hintergrund klären (Netzsuche darf das Menü nicht einfrieren). interactive = false: nie
    /// einen Dialog öffnen, nur beim nächsten Klick nach dem Passwort fragen.
    private func joinWithCredentials(_ row: RowInfo, interactive: Bool) {
        let ssid = row.ssid
        let seen = inRange[ssid]
        DispatchQueue.global(qos: .userInitiated).async {
            let (secure, enterprise) = self.security(of: ssid, seen: seen)
            RunLoop.main.perform(inModes: [.common]) {
                self.proceed(ssid, secure: secure, enterprise: enterprise, interactive: interactive)
            }
        }
    }

    private func proceed(_ ssid: String, secure: Bool, enterprise: Bool, interactive: Bool) {
        // Offenes Netz: direkt.
        if !secure { joinWithPassword(ssid, credentials: nil); return }
        guard interactive else {
            askAgain.insert(ssid)
            if failed == ssid { failedReason = L("Passwort nötig – nochmal klicken", "Password needed – click again") }
            updatePanel()
            return
        }
        openMenu?.cancelTracking()   // Dialog nicht hinter dem offenen Menü
        guard let credentials = askPassword(ssid, enterprise: enterprise) else { return }
        joinWithPassword(ssid, credentials: credentials)
    }

    /// Was verlangt das Netz? (geschützt?, Benutzername nötig?) Der Reihe nach: aktuelle
    /// Suchliste, System-Zwischenspeicher, gespeichertes macOS-Profil, gezielte Suche.
    func security(of ssid: String, seen: Seen?) -> (secure: Bool, enterprise: Bool) {
        if let seen = seen { return (seen.secure, seen.enterprise) }
        if let iface = Wifi.iface,
           let n = (iface.cachedScanResults() ?? []).first(where: { $0.ssid == ssid }) {
            return (n.needsCredentials, n.isEnterprise)
        }
        if let sec = CoreWiFi.profileSecurity(ssid) {
            let open = sec == "none" || sec == "open" || sec.hasPrefix("owe")   // OWE: verschlüsselt, ohne Passwort
            return (!open, sec.contains("enterprise") || sec.contains("eap") || sec.contains("802.1x"))
        }
        if let iface = Wifi.iface,
           let n = (try? iface.scanForNetworks(withName: ssid))?.max(by: { $0.rssiValue < $1.rssiValue }) {
            return (n.needsCredentials, n.isEnterprise)
        }
        return (true, false)   // unbekannt: Passwort annehmen
    }

    /// Fragt die WLAN-Zugangsdaten ab (nicht das Mac-Passwort): Passwort, bei Enterprise-Netzen
    /// (z. B. Schule, Uni, Firma, eduroam) zusätzlich den Benutzernamen. nil = abgebrochen.
    func askPassword(_ ssid: String, enterprise: Bool) -> WifiCredentials? {
        let (alert, user, pass) = Self.passwordAlert(ssid, enterprise: enterprise)
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, !pass.stringValue.isEmpty,
              !enterprise || !user.stringValue.isEmpty else { return nil }
        let name = user.stringValue.trimmingCharacters(in: .whitespaces)
        return WifiCredentials(username: enterprise ? name : nil, password: pass.stringValue)
    }

    /// Baut den Anmelde-Dialog (ohne ihn anzuzeigen).
    static func passwordAlert(_ ssid: String, enterprise: Bool) -> (NSAlert, NSTextField, NSSecureTextField) {
        let alert = NSAlert()
        alert.icon = wifiAlertIcon
        alert.messageText = enterprise
            ? L("Anmeldung für „\(ssid)“", "Sign in to “\(ssid)”")
            : L("WLAN-Passwort für „\(ssid)“", "Wi-Fi password for “\(ssid)”")
        alert.informativeText = enterprise ? L("Benutzername und Passwort eingeben.", "Enter username and password.")
                                           : L("Passwort eingeben.", "Enter the password.")

        let width: CGFloat = 260
        let user = NSTextField(frame: .zero)
        user.placeholderString = L("Benutzername", "Username")
        let pass = NSSecureTextField(frame: .zero)
        pass.placeholderString = L("Passwort", "Password")

        let rows: [NSView] = enterprise ? [user, pass] : [pass]
        let box = NSView(frame: NSRect(x: 0, y: 0, width: width, height: CGFloat(rows.count) * 30))
        for (n, v) in rows.enumerated() {   // von oben nach unten
            v.frame = NSRect(x: 0, y: box.frame.height - CGFloat(n + 1) * 30 + 4, width: width, height: 24)
            box.addSubview(v)
        }
        alert.accessoryView = box
        alert.addButton(withTitle: L("Verbinden", "Join"))
        alert.addButton(withTitle: L("Abbrechen", "Cancel"))
        alert.window.initialFirstResponder = enterprise ? user : pass
        return (alert, user, pass)
    }

    /// Verbindet über die öffentliche CoreWLAN-Schnittstelle. Das Passwort bleibt nur für diesen
    /// Versuch im Prozess; nach erfolgreicher Verbindung merkt sich macOS das Netz selbst.
    func joinWithPassword(_ ssid: String, credentials: WifiCredentials?) {
        let cached = inRange[ssid]?.network
        /// Schnell: erst mit dem schon bekannten Suchergebnis verbinden (wie Apple), nur ohne
        /// eines oder beim zweiten Versuch gezielt neu suchen (kostet 1–4 s).
        func attempt(fresh: Bool) -> String? {
            guard let iface = Wifi.iface else { return "WLAN nicht verfügbar" }
            let scanned = fresh || cached == nil
                ? (try? iface.scanForNetworks(withName: ssid))?.max { $0.rssiValue < $1.rssiValue } : nil
            guard let network = scanned ?? cached else { return "Netz nicht in Reichweite" }
            do {
                if network.isEnterprise, let c = credentials {
                    // 802.1X: Benutzername + Passwort (ohne Zertifikat-Identität)
                    try iface.associate(toEnterpriseNetwork: network, identity: nil,
                                        username: c.username, password: c.password)
                } else {
                    try iface.associate(to: network, password: credentials?.password)
                }
                return nil
            }
            catch {
                NSLog("Wifi Usage: Verbinden mit \(ssid) fehlgeschlagen: \(error.localizedDescription)")
                // Gleich ein zweiter Versuch mit frischer Suche: Hotspots scheitern beim ersten
                // Mal oft kurz (Funkband-Wechsel), ohne dass das Passwort falsch wäre.
                if !fresh { return attempt(fresh: true) }
                return error.localizedDescription
            }
        }
        connect(ssid, attempt: { attempt(fresh: false) }, completion: { [weak self] joined, _ in
            guard let self = self else { return }
            if joined { self.askAgain.remove(ssid) }
            else if credentials != nil { self.askAgain.insert(ssid) }   // nächster Klick fragt neu
        })
    }

    /// Verbindungsaufbau mit „Verbinde …"-Anzeige. Ob es geklappt hat, entscheidet allein, ob man
    /// danach wirklich in diesem WLAN ist — networksetup/CoreWLAN melden teils Fehler, obwohl es klappt.
    func connect(_ ssid: String, attempt: @escaping () -> String?, retry: (() -> String?)? = nil,
                 completion: ((Bool, String?) -> Void)? = nil) {
        joinGeneration += 1
        let generation = joinGeneration
        joining = ssid
        failed = nil
        updatePanel()
        armAutoClose()
        joinAnimation?.invalidate()
        joinFrame = 0
        let anim = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.joinFrame += 1
            self.updateTitle()
        }
        RunLoop.main.add(anim, forMode: .common)
        joinAnimation = anim
        DispatchQueue.global(qos: .userInitiated).async {
            let started = Date()
            NSLog("Wifi Usage: Wechsel zu \(ssid) gestartet (vorher: \(Wifi.iface?.ssid() ?? "kein WLAN"))")
            var lastMessage = attempt()
            var retried = false
            if lastMessage != nil, let retry = retry {   // sofort abgelehnt: gleich nachfassen
                lastMessage = retry()
                retried = true
            }
            // Beide Versuche abgelehnt: nur kurz prüfen, ob es trotzdem klappt, statt 15 s zu warten.
            let steps = retried && lastMessage != nil ? 6 : 30
            var joined = false
            for step in 0..<steps {   // bis zu 15 s
                if Wifi.iface?.ssid() == ssid { joined = true; break }
                if generation != self.joinGeneration { break }   // inzwischen anderes Netz gewählt
                if step == 10, !retried, let retry = retry { lastMessage = retry() ?? lastMessage }   // nach 5 s einmal nachfassen
                Thread.sleep(forTimeInterval: 0.5)
            }
            NSLog("Wifi Usage: Wechsel zu \(ssid) " + (joined ? "verbunden" : "nicht verbunden")
                  + String(format: " nach %.1f s", Date().timeIntervalSince(started))
                  + (generation != self.joinGeneration ? " (überholt)" : ""))
            RunLoop.main.perform(inModes: [.common]) {
                guard generation == self.joinGeneration else { return }   // überholt: still beenden
                self.joining = nil
                self.joinAnimation?.invalidate(); self.joinAnimation = nil
                self.refresh()
                if !joined {
                    // Kein Popup: kurz „Fehlgeschlagen" am Netz, wie im Apple-Menü.
                    self.failed = ssid
                    self.failedReason = lastMessage == "Netz nicht in Reichweite"
                        ? L("Nicht in Reichweite", "Not in range") : L("Fehlgeschlagen", "Failed")
                    Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                        guard let self = self, self.failed == ssid else { return }
                        self.failed = nil
                        self.updatePanel()
                    }
                }
                completion?(joined, lastMessage)
                self.updatePanel()
                self.armAutoClose()
            }
        }
    }

    func setPower(_ on: Bool) {
        powerTarget = on
        updatePanel()   // Schalter und (gemerkte) Netzliste sofort, nicht erst nach dem System
        armAutoClose()
        DispatchQueue.global(qos: .userInitiated).async {
            // Direkt über CoreWLAN (schnell, kein externer Prozess); networksetup nur als Rückfall.
            do { try Wifi.iface?.setPower(on) }
            catch { _ = Sys.run("/usr/sbin/networksetup", ["-setairportpower", Sys.wifiInterface(), on ? "on" : "off"]) }
            RunLoop.main.perform(inModes: [.common]) {
                self.powerTarget = nil
                self.refresh()
                self.updatePanel()
                if on { self.scanAsync(retries: 4) }   // Funk braucht kurz, bis die Suche Ergebnisse liefert
            }
        }
    }

    @objc func openWifiSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")!)
    }

    @objc func openLocationSettings() {
        if location.authorizationStatus == .notDetermined {
            NSApp.activate(ignoringOtherApps: true)
            location.requestWhenInUseAuthorization()
            return
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
    }

    /// Fenster beim ersten Mal anlegen, danach nur wieder nach vorne holen.
    func show<V: View>(_ window: inout NSWindow?, title: String, size: NSSize, resizable: Bool, _ view: () -> V) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: view()))
            w.styleMask = resizable ? [.titled, .closable, .miniaturizable, .resizable] : [.titled, .closable]
            w.setContentSize(size)
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.title = title
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc func openOverview() {
        overview.reload()
        show(&overviewWindow, title: L("Wifi Usage – Übersicht", "Wifi Usage – Overview"),
             size: NSSize(width: 640, height: 760), resizable: true) { OverviewView(model: overview) }
    }

    @objc func openSettings() {
        let isNew = settingsWindow == nil
        show(&settingsWindow, title: L("Einstellungen", "Settings"),
             size: NSSize(width: 480, height: 640), resizable: false) { SettingsView() }
        // Beim Schließen verwerfen: nächstes Öffnen startet frisch (Beobachter nur einmal je Fenster).
        if isNew, let w = settingsWindow {
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                self?.settingsWindow = nil
            }
        }
    }

    func openCoffee() {
        UserDefaults.standard.set(true, forKey: "coffeeSeen")   // nur beim ersten Start automatisch
        show(&coffeeWindow, title: "Buy Me a Coffee", size: NSSize(width: 380, height: 360), resizable: false) {
            CoffeeView { [weak self] in self?.coffeeWindow?.close() }
        }
    }

    @objc func refresh() {
        Meter.sample(); updateTitle()
        if overviewWindow?.isVisible == true { overview.reload() }
    }
}

// MARK: - Menüzeilen im Apple-Stil
struct Seen {
    let rssi: Int
    let secure: Bool
    let network: CWNetwork?
    let seenAt: Date
    var enterprise = false   // WPA/WPA2/WPA3-Enterprise (802.1X): Benutzername + Passwort
}

extension CWNetwork {
    /// Braucht Zugangsdaten? Offen und OWE („Enhanced Open", verschlüsselt ohne Passwort) nicht.
    var needsCredentials: Bool {
        !(supportsSecurity(.none) || supportsSecurity(.OWE) || supportsSecurity(.oweTransition))
    }
    var isEnterprise: Bool {
        supportsSecurity(.wpaEnterprise) || supportsSecurity(.wpa2Enterprise)
            || supportsSecurity(.wpa3Enterprise) || supportsSecurity(.enterprise)
    }
}

let MENU_WIDTH: CGFloat = 300

/// Grundzeile: abgerundete Hover-Fläche wie im Kontrollzentrum, Klick schließt das Menü.
class MenuRowView: NSView {
    var onClick: (() -> Void)?
    var keepsMenuOpen = false   // z. B. Auf-/Zuklappen: Menü bleibt offen
    var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
    var onHover: (() -> Void)?
    override func mouseEntered(with event: NSEvent) { if onClick != nil { hovered = true }; onHover?() }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseUp(with event: NSEvent) {
        guard let click = onClick else { return }
        if !keepsMenuOpen { enclosingMenuItem?.menu?.cancelTracking() }
        hovered = false
        // .common: läuft auch im Event-Tracking-Modus des offenen Menüs
        RunLoop.main.perform(inModes: [.common], block: click)
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            NSColor.labelColor.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
    }
}

/// Fußzeile: Titel links (Klick = onClick), Zahnrad rechts (Klick = onGear) — jeweils eigener Hover.
final class FooterRowView: MenuRowView {
    var onGear: (() -> Void)?
    private let title: String
    private enum Part { case none, title, gear }
    private var part = Part.none { didSet { if part != oldValue { needsDisplay = true } } }

    init(title: String) {
        self.title = title
        super.init(frame: NSRect(x: 0, y: 0, width: MENU_WIDTH, height: 30))
    }
    required init?(coder: NSCoder) { fatalError() }

    private var gearRect: NSRect { NSRect(x: bounds.width - 12 - 26, y: (bounds.height - 26) / 2, width: 26, height: 26) }
    private var split: CGFloat { gearRect.minX - 4 }
    private func part(at event: NSEvent) -> Part {
        convert(event.locationInWindow, from: nil).x >= split ? .gear : .title
    }

    // Menüs liefern keine mouseMoved-Ereignisse -> zwei getrennte Bereiche mit Rein/Raus.
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        let opts: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways]
        addTrackingArea(NSTrackingArea(rect: NSRect(x: 0, y: 0, width: split, height: bounds.height),
                                       options: opts, owner: self, userInfo: ["part": "title"]))
        addTrackingArea(NSTrackingArea(rect: NSRect(x: split, y: 0, width: bounds.width - split, height: bounds.height),
                                       options: opts, owner: self, userInfo: ["part": "gear"]))
    }
    private func area(_ event: NSEvent) -> Part {
        (event.trackingArea?.userInfo?["part"] as? String) == "gear" ? .gear : .title
    }
    override func mouseEntered(with event: NSEvent) { part = area(event) }
    override func mouseExited(with event: NSEvent) { if part == area(event) { part = .none } }
    override func mouseUp(with event: NSEvent) {
        let action = part(at: event) == .gear ? onGear : onClick
        guard let a = action else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        part = .none
        RunLoop.main.perform(inModes: [.common], block: a)
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill = NSColor.labelColor.withAlphaComponent(0.1)
        if part == .title {
            fill.setFill()
            NSBezierPath(roundedRect: NSRect(x: 5, y: 1, width: gearRect.minX - 4 - 5 - 4, height: bounds.height - 2),
                         xRadius: 6, yRadius: 6).fill()
        } else if part == .gear {
            fill.setFill()
            NSBezierPath(ovalIn: gearRect).fill()
        }
        let t = NSAttributedString(string: title, attributes: [
            .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.labelColor])
        t.draw(at: NSPoint(x: 14, y: (bounds.height - t.size().height) / 2))

        let tint: NSColor = part == .gear ? .labelColor : .secondaryLabelColor
        if let g = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))) {
            g.draw(in: NSRect(x: gearRect.midX - g.size.width / 2, y: gearRect.midY - g.size.height / 2,
                              width: g.size.width, height: g.size.height))
        }
    }
}

/// Schalter im Stil von Apples WLAN-Menü: Akzentfarbe (blau) wenn an, grau wenn aus.
/// Selbst gezeichnet, weil NSSwitch im (nie aktiven) Menüfenster immer grau bleibt.
final class MenuToggle: NSView {
    var isOn: Bool { didSet { needsDisplay = true } }
    var onChange: ((Bool) -> Void)?

    init(isOn: Bool) {
        self.isOn = isOn
        super.init(frame: NSRect(x: 0, y: 0, width: 38, height: 22))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseUp(with event: NSEvent) {
        isOn.toggle()
        let v = isOn
        if let c = onChange { RunLoop.main.perform(inModes: [.common]) { c(v) } }
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        (isOn ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.15)).setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()

        let d = r.height - 4
        let knob = NSRect(x: isOn ? r.maxX - 2 - d : r.minX + 2, y: r.minY + 2, width: d, height: d)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// „WLAN" fett links, Schalter rechts.
final class HeaderRowView: MenuRowView {
    init(title: String, isOn: Bool, scanning: Bool = false, toggle: @escaping (Bool) -> Void) {
        super.init(frame: NSRect(x: 0, y: 0, width: MENU_WIDTH, height: 36))
        if scanning {
            // kleiner Warte-Kreis links vom Schalter, solange gesucht wird
            let spinner = NSProgressIndicator(frame: NSRect(x: bounds.width - 14 - 38 - 8 - 14, y: (bounds.height - 14) / 2,
                                                            width: 14, height: 14))
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.usesThreadedAnimation = true
            addSubview(spinner)
            spinner.startAnimation(nil)
        }
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: 13)
        label.sizeToFit()
        label.frame.origin = NSPoint(x: 14, y: (bounds.height - label.frame.height) / 2)
        addSubview(label)
        let sw = MenuToggle(isOn: isOn)
        sw.frame.origin = NSPoint(x: bounds.width - sw.frame.width - 14, y: (bounds.height - sw.frame.height) / 2)
        sw.onChange = toggle
        addSubview(sw)
        self.sw = sw
    }
    required init?(coder: NSCoder) { fatalError() }
    private weak var sw: MenuToggle?

    // Falls das Menü den Klick an die Zeile statt an den Schalter liefert: weiterreichen.
    override func mouseUp(with event: NSEvent) {
        guard let sw = sw, sw.frame.insetBy(dx: -6, dy: -6).contains(convert(event.locationInWindow, from: nil)) else { return }
        sw.mouseUp(with: event)
    }
}

/// Abschnittskopf zum Auf-/Zuklappen (wie „Andere Netzwerke" bei Apple).
final class DisclosureRowView: MenuRowView {
    private let title: String
    var expanded: Bool { didSet { needsDisplay = true } }

    init(title: String, expanded: Bool) {
        self.title = title
        self.expanded = expanded
        super.init(frame: NSRect(x: 0, y: 0, width: MENU_WIDTH, height: 26))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let t = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
        t.draw(at: NSPoint(x: 14, y: (bounds.height - t.size().height) / 2))
        if let c = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor]))) {
            c.draw(in: NSRect(x: bounds.width - 16 - c.size.width, y: (bounds.height - c.size.height) / 2,
                              width: c.size.width, height: c.size.height))
        }
    }
}

/// Netz-Zeile: rundes Symbol (blau = verbunden), Name, optional Verbrauch, Schloss.
final class NetworkRowView: MenuRowView {
    let title: String, subtitle: String?, detail: String?
    let symbol: String, signal: Double?, connected: Bool, secure: Bool, joining: Bool

    init(title: String, subtitle: String?, detail: String?, symbol: String,
         signal: Double?, connected: Bool, secure: Bool, joining: Bool = false) {
        self.title = title; self.subtitle = subtitle; self.detail = detail
        self.symbol = symbol; self.signal = signal; self.connected = connected; self.secure = secure
        self.joining = joining
        super.init(frame: NSRect(x: 0, y: 0, width: MENU_WIDTH, height: subtitle == nil ? 38 : 44))
        if joining {
            // Warte-Kreis im runden Symbol, solange die Verbindung aufgebaut wird
            let spinner = NSProgressIndicator(frame: NSRect(x: 14 + 5, y: (bounds.height - 16) / 2, width: 16, height: 16))
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            spinner.usesThreadedAnimation = true   // dreht auch, während das Menü offen ist
            addSubview(spinner)
            spinner.startAnimation(nil)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let h = bounds.height

        // Kreis mit Symbol
        let d: CGFloat = 26
        let circle = NSRect(x: 14, y: (h - d) / 2, width: d, height: d)
        (connected ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.1)).setFill()
        NSBezierPath(ovalIn: circle).fill()
        let tint: NSColor = connected ? .white : .labelColor
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        let base = symbol == "wifi" && signal != nil
            ? NSImage(systemSymbolName: "wifi", variableValue: signal!, accessibilityDescription: nil)
            : NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        if !joining, let img = base?.withSymbolConfiguration(cfg) {
            img.draw(in: NSRect(x: circle.midX - img.size.width / 2, y: circle.midY - img.size.height / 2,
                                width: img.size.width, height: img.size.height))
        }

        // rechts: Schloss, davor Verbrauch
        var right = bounds.width - 16
        if secure, let lock = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor]))) {
            right -= lock.size.width
            lock.draw(in: NSRect(x: right, y: (h - lock.size.height) / 2, width: lock.size.width, height: lock.size.height))
            right -= 8
        }
        if let detail = detail {
            let s = NSAttributedString(string: detail, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor])
            right -= s.size().width
            s.draw(at: NSPoint(x: right, y: (h - s.size().height) / 2))
            right -= 8
        }

        // Name (+ Untertitel)
        let x = circle.maxX + 10
        let t = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        let maxW = right - x
        if let sub = subtitle {
            let st = NSAttributedString(string: sub, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor])
            t.draw(with: NSRect(x: x, y: h / 2 + 1, width: maxW, height: 17), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            st.draw(with: NSRect(x: x, y: h / 2 - 15, width: maxW, height: 15), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        } else {
            t.draw(with: NSRect(x: x, y: (h - 17) / 2, width: maxW, height: 17), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}

/// Eine Netzzeile im WLAN-Bereich.
struct RowInfo {
    let ssid: String
    let detail: String?      // Verbrauch oder „Verbinde …"
    let symbol: String
    let signal: Double?
    let connected: Bool
    let secure: Bool
    let known: Bool
    let tooltip: String?
    var joining = false
    var subtitle: String? = nil
}

/// Inhalt des WLAN-Bereichs.
struct PanelContent {
    var wifiOn: Bool
    var othersExpanded: Bool
    var known: [RowInfo] = []
    var knownHint: String?
    var others: [RowInfo] = []
    var othersHint: String?
    var scanning = false
}

/// WLAN-Bereich des Menüs als ein einziger Eintrag: Schalter, Persönlicher Hotspot, Bekannte und
/// (aufklappbar) Andere Netzwerke. update() tauscht nur die Unteransichten und die Höhe.
final class WifiPanelView: NSView {
    var onPower: ((Bool) -> Void)?
    var onSelect: ((RowInfo) -> Void)?
    var onToggleOthers: ((Bool) -> Void)?
    var onActivity: (() -> Void)?
    private var content = PanelContent(wifiOn: false, othersExpanded: false)

    override var isFlipped: Bool { true }   // von oben nach unten stapeln

    init() { super.init(frame: NSRect(x: 0, y: 0, width: MENU_WIDTH, height: 36)) }
    required init?(coder: NSCoder) { fatalError() }

    func update(_ c: PanelContent) {
        content = c
        relayout()
    }

    private func relayout() {
        subviews.forEach { $0.removeFromSuperview() }
        var y: CGFloat = 0
        func add(_ v: NSView) { v.frame.origin = NSPoint(x: 0, y: y); addSubview(v); y += v.frame.height }
        func separator() {
            let box = NSView(frame: NSRect(x: 0, y: 0, width: MENU_WIDTH, height: 11))
            let line = NSBox(frame: NSRect(x: 14, y: 5, width: MENU_WIDTH - 28, height: 1))
            line.boxType = .separator
            box.addSubview(line)
            add(box)
        }
        func label(_ text: String, header: Bool) {
            let l = NSTextField(labelWithString: text)
            l.font = header ? .systemFont(ofSize: 12, weight: .semibold) : .menuFont(ofSize: 0)
            l.textColor = .secondaryLabelColor
            l.sizeToFit()
            let box = NSView(frame: NSRect(x: 0, y: 0, width: MENU_WIDTH, height: header ? 24 : 26))
            l.frame.origin = NSPoint(x: 14, y: (box.frame.height - l.frame.height) / 2)
            box.addSubview(l)
            add(box)
        }
        func row(_ r: RowInfo) {
            let v = NetworkRowView(title: r.ssid, subtitle: r.subtitle, detail: r.detail, symbol: r.symbol,
                                   signal: r.signal, connected: r.connected, secure: r.secure, joining: r.joining)
            v.toolTip = r.tooltip
            // Wechseln lässt das Menü offen; Übersicht und Passwortabfrage schließen es selbst.
            v.keepsMenuOpen = true
            v.onClick = { [weak self] in self?.onSelect?(r) }
            v.onHover = { [weak self] in self?.onActivity?() }
            add(v)
        }

        let header = HeaderRowView(title: L("WLAN", "Wi-Fi"), isOn: content.wifiOn,
                                   scanning: content.wifiOn && content.scanning) { [weak self] on in
            self?.onPower?(on)
        }
        add(header)

        if content.wifiOn {
            if !content.known.isEmpty {
                separator(); label(L("Bekannte Netzwerke", "Known Networks"), header: true)
                content.known.forEach(row)
            }
            if let h = content.knownHint { separator(); label(h, header: false) }

            separator()
            let disclosure = DisclosureRowView(title: L("Andere Netzwerke", "Other Networks"),
                                               expanded: content.othersExpanded)
            disclosure.keepsMenuOpen = true
            disclosure.onHover = { [weak self] in self?.onActivity?() }
            disclosure.onClick = { [weak self] in
                guard let self = self else { return }
                self.content.othersExpanded.toggle()
                self.onToggleOthers?(self.content.othersExpanded)
                self.relayout()
            }
            add(disclosure)
            if content.othersExpanded {
                if let h = content.othersHint { label(h, header: false) }
                content.others.forEach(row)
            }
        }

        setFrameSize(NSSize(width: MENU_WIDTH, height: y))
        if let item = enclosingMenuItem { item.menu?.itemChanged(item) }   // Menü passt die Höhe an
    }
}

// MARK: - Übersicht (Fenster): Statistik analysieren
final class OverviewModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case month, year
        var id: String { rawValue }
        var title: String { self == .month ? L("Monat", "Month") : L("Jahr", "Year") }
    }
    @Published var mode = Mode.month
    @Published var month = Meter.monthKey()
    @Published var year = String(Meter.monthKey().prefix(4))
    @Published var months: [String] = []   // neueste zuerst
    @Published var years: [String] = []
    @Published var revision = 0            // erhöht sich bei jeder Messung -> Ansicht neu zeichnen

    func reload() {
        months = Set(Storage.shared.store.months.keys).union([Meter.monthKey()]).sorted(by: >)
        years = Array(Set(months.map { String($0.prefix(4)) })).sorted(by: >)
        if !months.contains(month) { month = Meter.monthKey() }
        if !years.contains(year) { year = years.first ?? year }
        revision += 1
    }
    var period: Period { Period(key: mode == .month ? month : year) }
    private var keys: [String] { mode == .month ? months : years }
    private var current: String { mode == .month ? month : year }
    var canOlder: Bool { keys.last != current }
    var canNewer: Bool { keys.first != current }
    /// +1 = neuer, -1 = älter (im gewählten Modus)
    func step(_ d: Int) {
        guard let i = keys.firstIndex(of: current), keys.indices.contains(i - d) else { return }
        if mode == .month { month = keys[i - d] } else { year = keys[i - d] }
    }
}

// Feste Farbe pro Netz (Rang nach Gesamtverbrauch aller Monate), in allen Ansichten gleich.
// Reihenfolge und Stufen aus einer farbenblind-geprüften Palette; ab Platz 6 grau „Andere".
enum Palette {
    static let slots: [(light: UInt32, dark: UInt32)] = [
        (0x2a78d6, 0x3987e5), (0xeb6834, 0xd95926), (0x1baf7a, 0x199e70),
        (0xeda100, 0xc98500), (0xe87ba4, 0xd55181)]
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            let v = ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                           blue: CGFloat(v & 0xff) / 255, alpha: 1)
        })
    }
    static let other = dynamic(0x9a988f, 0x6f6e69)
}

struct ColorMap {
    let top: [String]
    init() {
        var g: [String: UInt64] = [:]
        for m in Storage.shared.store.months.keys {
            for n in Meter.grouped(month: m) { g[n.name, default: 0] &+= n.usage.total }
        }
        top = Array(g.filter { $0.value > 0 }.sorted { $0.value > $1.value }.prefix(Palette.slots.count).map(\.key))
    }
    func color(_ name: String) -> Color {
        guard let i = top.firstIndex(of: name) else { return Palette.other }
        return Palette.dynamic(Palette.slots[i].light, Palette.slots[i].dark)
    }
    func bucket(_ name: String) -> String { top.contains(name) ? name : L("Andere", "Other") }
    var domain: [String] { top + [L("Andere", "Other")] }
    var range: [Color] { top.map(color) + [Palette.other] }
}

func shortDate(_ d: Date) -> String {
    d.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: Prefs.shared.isGerman ? "de_AT" : "en_US")))
}

struct OverviewView: View {
    @ObservedObject var model: OverviewModel
    @ObservedObject var prefs = Prefs.shared   // Sprachwechsel -> neu zeichnen

    var body: some View {
        let _ = (model.revision, prefs.language)
        let period = model.period
        let list = Meter.grouped(period: period)
        let total = sum(list)
        let colors = ColorMap()
        let prev = period.previous
        let daily = DailyChart.points(month: model.month)
        let avg = daily.isEmpty ? 0 : daily.map(\.gb).reduce(0, +) / Double(daily.count)
        let monthsWithData = Storage.shared.store.months.filter { period.contains(monthKey: $0.key) && !$0.value.isEmpty }.count

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Kopf: Zeitraum blättern, Monat/Jahr, Zahnrad
                HStack(spacing: 6) {
                    Button { model.step(-1) } label: { Image(systemName: "chevron.left") }
                        .disabled(!model.canOlder)
                    Text(period.title)
                        .font(.title2.weight(.semibold))
                        .frame(minWidth: 170)
                    Button { model.step(1) } label: { Image(systemName: "chevron.right") }
                        .disabled(!model.canNewer)
                    Spacer()
                    Picker("", selection: $model.mode) {
                        ForEach(OverviewModel.Mode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Button { Actions.openSettings() } label: {
                        Image(systemName: "gearshape").font(.system(size: 15))
                    }
                    .help(L("Einstellungen", "Settings"))
                    .padding(.leading, 8)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 14, weight: .semibold))

                // Kennzahl
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("Verbrauch gesamt", "Total usage"))
                            .font(.subheadline).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(String(format: "%.2f", gbValue(total.total)))
                                .font(.system(size: 42, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                            Text("GB").font(.title3.weight(.medium)).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 16) {
                            Label(gb(total.down), systemImage: "arrow.down")
                            Label(gb(total.up), systemImage: "arrow.up")
                            if prev.hasData {
                                Text((period.isYear ? L("Vorjahr", "Previous year") : L("Vormonat", "Previous month"))
                                     + ": " + gb(sum(Meter.grouped(period: prev)).total))
                            }
                            if period.isYear, monthsWithData > 0 {
                                Text(L("Ø pro Monat", "Avg per month") + ": "
                                     + String(format: "%.2f GB", gbValue(total.total) / Double(monthsWithData)))
                            }
                        }
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                }

                Card(title: L("Netze", "Networks")) {
                    NetworkList(period: period, list: list, total: total.total, colors: colors)
                }

                if period.isYear {
                    Card(title: L("Pro Monat", "Per month")) {
                        YearChart(year: model.year, colors: colors)
                    }
                    if model.years.count > 1 {
                        Card(title: L("Jahre im Vergleich", "Years compared")) {
                            YearsChart(years: model.years, selected: model.year)
                        }
                    }
                } else {
                    Card(title: L("Pro Tag", "Per day"),
                         trailing: avg > 0 ? "Ø " + String(format: "%.2f GB", avg) + L(" / Tag", " / day") : nil) {
                        DailyChart(month: model.month, data: daily, average: avg)
                    }
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 560, minHeight: 500)
    }
}

/// Karte im Stil der Systemeinstellungen.
struct Card<Content: View>: View {
    var title: String? = nil
    var trailing: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = title {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    if let t = trailing { Text(t).font(.callout).foregroundStyle(.secondary).monospacedDigit() }
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.07)))
    }
}

/// Netze als Liste: Farbpunkt, Name, Anteilsbalken, GB und Prozent (zugleich die Tabelle).
struct NetworkList: View {
    let period: Period
    let list: [NetUsage]
    let total: UInt64
    let colors: ColorMap
    @State private var expanded: String?   // aufgeklapptes Netz

    var body: some View {
        let shown = list.filter { gbValue($0.usage.total) >= 0.01 }
        let hidden = list.count - shown.count
        if shown.isEmpty {
            Text(period.isYear ? L("Für dieses Jahr gibt es noch keine Daten.", "No data for this year yet.")
                               : L("Für diesen Monat gibt es noch keine Daten.", "No data for this month yet."))
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 14) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, n in
                    let frac = total > 0 ? Double(n.usage.total) / Double(total) : 0
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Circle().fill(colors.color(n.name)).frame(width: 8, height: 8)
                            Text(n.name).lineLimit(1).truncationMode(.middle)
                            if n.name == Meter.currentNet?.name {
                                Text(L("Verbunden", "Connected"))
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                    .foregroundStyle(Color.accentColor)
                            }
                            Spacer(minLength: 8)
                            Text(gb(n.usage.total)).fontWeight(.medium)
                            Text(String(format: "%.0f %%", frac * 100))
                                .foregroundStyle(.secondary)
                                .frame(width: 42, alignment: .trailing)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(expanded == n.name ? 90 : 0))
                        }
                        .monospacedDigit()
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.07))
                                Capsule().fill(colors.color(n.name))
                                    .frame(width: max(4, g.size.width * frac))
                            }
                        }
                        .frame(height: 6)

                        if expanded == n.name {
                            NetworkDetail(period: period, net: n, color: colors.color(n.name))
                                .padding(.top, 6)
                                // erst Platz schaffen, dann einblenden; beim Zuklappen sofort weg
                                .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.12)),
                                                        removal: .opacity.animation(.easeIn(duration: 0.08))))
                        }
                    }
                    // spätere Zeilen liegen oben und decken das Detail während der Animation ab
                    .background(Color(nsColor: .controlBackgroundColor))
                    .zIndex(Double(index))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) { expanded = expanded == n.name ? nil : n.name }
                    }
                    .help(L("Klicken für Details", "Click for details"))
                }
                if hidden > 0 {
                    Text(hidden == 1 ? L("+ 1 Netz unter 0.01 GB", "+ 1 network under 0.01 GB")
                                     : L("+ \(hidden) Netze unter 0.01 GB", "+ \(hidden) networks under 0.01 GB"))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// Details zu einem Netz im gewählten Zeitraum (aufgeklappt in der Netzliste).
/// Monat: Werte pro Tag. Jahr: Werte pro Monat.
struct NetworkDetail: View {
    let period: Period
    let net: NetUsage
    let color: Color

    /// Verbrauch dieses Netzes je Tag (Monat) bzw. je Monat (Jahr), nur Einträge > 0.
    var points: [DayPoint] {
        let st = Storage.shared.store
        if period.isYear {
            return st.months.keys.filter { period.contains(monthKey: $0) }.sorted().compactMap { k in
                guard let d = DailyChart.keyFormat.date(from: k + "-01") else { return nil }
                let v = Meter.usage(month: k, name: net.name)
                return v.total > 0 ? DayPoint(date: d, gb: gbValue(v.total)) : nil
            }
        }
        return st.days.keys.filter { period.contains(dayKey: $0) }.sorted().compactMap { k in
            guard let d = DailyChart.keyFormat.date(from: k),
                  let v = Meter.grouped(day: k).first(where: { $0.name == net.name }), v.usage.total > 0 else { return nil }
            return DayPoint(date: d, gb: gbValue(v.usage.total))
        }
    }

    var body: some View {
        let u = net.usage
        let pts = points
        let year = period.isYear
        // Tageswerte gibt es erst seit Einführung der Tageszählung -> Rest ist keinem Tag zugeordnet.
        let firstDay = Storage.shared.store.days.keys.min().flatMap { DailyChart.keyFormat.date(from: $0) }
        let unassigned = year ? 0 : max(0, gbValue(u.total) - pts.map(\.gb).reduce(0, +))
        let partial = unassigned >= 0.01
        let mark = partial ? " *" : ""
        let prev = period.previous
        let downShare = u.total > 0 ? Double(u.down) / Double(u.total) : 0
        let peak = pts.max(by: { $0.gb < $1.gb })
        let unitLabel = year ? L("Monate mit Nutzung", "Months used") : L("Tage mit Nutzung", "Days used")
        let avgLabel = year ? L("Ø pro Monat", "Avg per month") : L("Ø pro Tag", "Avg per day")
        let peakLabel = year ? L("Spitzenmonat", "Peak month") : L("Spitzentag", "Peak day")
        let peakText = peak.map { p -> String in
            let when = year ? prettyMonth(String(DailyChart.keyFormat.string(from: p.date).prefix(7)), short: true)
                            : shortDate(p.date)
            return when + " · " + String(format: "%.2f GB", p.gb)
        } ?? "–"

        VStack(alignment: .leading, spacing: 12) {
            // Download / Upload mit Verhältnisbalken
            HStack(alignment: .firstTextBaseline) {
                Stat(label: "Download", value: gb(u.down), icon: "arrow.down")
                Spacer()
                Stat(label: "Upload", value: gb(u.up), icon: "arrow.up", trailing: true)
            }
            GeometryReader { g in
                HStack(spacing: 2) {
                    Capsule().fill(color).frame(width: max(3, (g.size.width - 2) * downShare))
                    Capsule().fill(color.opacity(0.35))
                }
            }
            .frame(height: 6)
            .help(String(format: L("%.0f %% Download · %.0f %% Upload", "%.0f %% download · %.0f %% upload"),
                         downShare * 100, (1 - downShare) * 100))

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    DetailCell(label: unitLabel + mark, value: pts.isEmpty ? "–" : "\(pts.count)")
                    DetailCell(label: avgLabel + mark,
                               value: pts.isEmpty ? "–" : String(format: "%.2f GB", pts.map(\.gb).reduce(0, +) / Double(pts.count)))
                    DetailCell(label: peakLabel + mark, value: peakText)
                }
                GridRow {
                    DetailCell(label: L("Zuletzt genutzt", "Last used"), value: lastUsed(days: pts))
                    DetailCell(label: year ? L("Vorjahr", "Previous year") : L("Vormonat", "Previous month"),
                               value: prev.hasData ? gb(Meter.usage(period: prev, name: net.name).total) : "–")
                    DetailCell(label: L("Download-Anteil", "Download share"),
                               value: u.total > 0 ? String(format: "%.0f %%", downShare * 100) : "–")
                }
            }

            if pts.count > 1 {
                let start = DailyChart.keyFormat.date(from: year ? period.key + "-01-01" : period.key + "-01") ?? Date()
                let end = Calendar.current.date(byAdding: year ? .year : .month, value: 1, to: start) ?? Date()
                Chart(pts) { p in
                    BarMark(x: .value(year ? L("Monat", "Month") : L("Tag", "Day"), p.date, unit: year ? .month : .day),
                            y: .value("GB", p.gb), width: .ratio(0.7))
                        .cornerRadius(2)
                        .foregroundStyle(color)
                }
                .chartXScale(domain: start...end)
                .chartXAxis {
                    if year {
                        AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.narrow)) }
                    } else {
                        AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisValueLabel(format: .dateTime.day()) }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                        AxisValueLabel()
                    }
                }
                .frame(height: 90)
            }

            if partial {
                let since = firstDay.map(shortDate) ?? "–"
                Text(L("* Pro Tag wird erst seit \(since) gezählt. \(String(format: "%.2f GB", unassigned)) dieses Monats liegen davor und sind keinem Tag zugeordnet – diese Werte beziehen sich nur auf die erfassten Tage.",
                       "* Daily usage is recorded since \(since). \(String(format: "%.2f GB", unassigned)) of this month came before that and has no day assigned – these values only cover the recorded days."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

extension NetworkDetail {
    /// „Jetzt verbunden" > genauer Zeitpunkt der letzten Verbindung > letzter Tag mit Verbrauch.
    func lastUsed(days: [DayPoint]) -> String {
        if net.name == Meter.currentNet?.name { return L("Jetzt verbunden", "Connected now") }
        if let t = Storage.shared.store.lastSeen[net.name] {
            let d = Date(timeIntervalSince1970: t)
            let time = d.formatted(.dateTime.hour().minute()
                .locale(Locale(identifier: Prefs.shared.isGerman ? "de_AT" : "en_US")))
            if Calendar.current.isDateInToday(d) { return L("Heute, ", "Today, ") + time }
            if Calendar.current.isDateInYesterday(d) { return L("Gestern, ", "Yesterday, ") + time }
            return shortDate(d) + ", " + time
        }
        return days.last.map { shortDate($0.date) } ?? "–"
    }
}

struct Stat: View {
    let label: String
    let value: String
    let icon: String
    var trailing = false
    var body: some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 2) {
            Label(label, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
    }
}

struct DetailCell: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).monospacedDigit().lineLimit(1)
        }
    }
}

struct DayPoint: Identifiable {
    let date: Date
    let gb: Double
    var id: Date { date }
}

/// Verbrauch pro Tag (alle Netze), Durchschnittslinie, Tooltip beim Überfahren.
struct DailyChart: View {
    let month: String
    let data: [DayPoint]
    let average: Double
    @State private var selected: Date?

    static let keyFormat: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    static func points(month: String) -> [DayPoint] {
        Storage.shared.store.days.keys.filter { $0.hasPrefix(month + "-") }.sorted().compactMap { k in
            guard let d = keyFormat.date(from: k) else { return nil }
            return DayPoint(date: d, gb: gbValue(sum(Meter.grouped(day: k)).total))
        }
    }

    var body: some View {
        if data.isEmpty {
            Text(L("Für diesen Monat gibt es keinen Tagesverlauf – der wird erst seit Oktober 2026 aufgezeichnet.",
                   "No daily data for this month – daily usage is recorded since October 2026."))
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // Achse immer über den ganzen Monat, sonst zeigt Charts bei wenigen Tagen Stunden.
            let start = Self.keyFormat.date(from: month + "-01") ?? Date()
            let end = Calendar.current.date(byAdding: .month, value: 1, to: start) ?? Date()
            let hit = selected.flatMap { s in data.first { Calendar.current.isDate($0.date, inSameDayAs: s) } }

            Chart {
                ForEach(data) { p in
                    BarMark(x: .value(L("Tag", "Day"), p.date, unit: .day), y: .value("GB", p.gb), width: .ratio(0.7))
                        .cornerRadius(3)
                        .foregroundStyle(Color.accentColor.opacity(hit == nil || hit?.id == p.id ? 1 : 0.35))
                }
                RuleMark(y: .value("Ø", average))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Color.secondary.opacity(0.7))
                if let h = hit {
                    RuleMark(x: .value(L("Tag", "Day"), h.date, unit: .day))
                        .foregroundStyle(Color.clear)
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            Tooltip(title: shortDate(h.date), value: String(format: "%.2f GB", h.gb))
                        }
                }
            }
            .chartXScale(domain: start...end)
            .chartXSelection(value: $selected)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel(format: .dateTime.day())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel()
                }
            }
            .frame(height: 170)
        }
    }
}

struct MonthPoint: Identifiable {
    let month: String   // "2026-10"
    let label: String   // "Okt 26"
    let name: String    // Netz oder „Andere"
    let gb: Double
    var id: String { month + "|" + name }
}

/// Ein Jahr: 12 Monate (Jän–Dez), gestapelt nach Netz, Tooltip mit Monatssumme.
struct YearChart: View {
    let year: String
    let colors: ColorMap
    @State private var hover: String?

    var body: some View {
        let order = colors.domain
        let labels = (1...12).map { String((Prefs.shared.isGerman ? MONTHS_DE : MONTHS_EN)[$0 - 1].prefix(3)) }
        let data: [MonthPoint] = (1...12).flatMap { m -> [MonthPoint] in
            let k = String(format: "%@-%02d", year, m)
            var g: [String: UInt64] = [:]
            for n in Meter.grouped(month: k) { g[colors.bucket(n.name), default: 0] &+= n.usage.total }
            return g.filter { $0.value > 0 }
                .sorted { (order.firstIndex(of: $0.key) ?? 99) < (order.firstIndex(of: $1.key) ?? 99) }
                .map { MonthPoint(month: k, label: labels[m - 1], name: $0.key, gb: gbValue($0.value)) }
        }
        let hoverTotal = hover.map { h in data.filter { $0.label == h }.map(\.gb).reduce(0, +) }

        if data.isEmpty {
            Text(L("Noch keine Daten.", "No data yet.")).foregroundStyle(.secondary)
        } else {
            Chart {
                ForEach(data) { p in
                    BarMark(x: .value(L("Monat", "Month"), p.label), y: .value("GB", p.gb), width: .ratio(0.6))
                        .foregroundStyle(by: .value(L("Netz", "Network"), p.name))
                }
                if let h = hover, let t = hoverTotal, t > 0 {
                    RuleMark(x: .value(L("Monat", "Month"), h))
                        .foregroundStyle(Color.clear)
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            Tooltip(title: h, value: String(format: "%.2f GB", t))
                        }
                }
            }
            .chartXScale(domain: labels)   // immer alle 12 Monate
            .chartForegroundStyleScale(domain: order, range: colors.range)
            .chartXSelection(value: $hover)
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel()
                }
            }
            .chartLegend(position: .bottom, alignment: .leading, spacing: 12)
            .frame(height: 220)
        }
    }
}

/// Jahressummen nebeneinander; gewähltes Jahr hervorgehoben.
struct YearsChart: View {
    let years: [String]
    let selected: String
    var body: some View {
        let data = years.sorted().map { y in DayPoint(date: DailyChart.keyFormat.date(from: y + "-01-01") ?? Date(),
                                                       gb: gbValue(sum(Meter.grouped(period: Period(key: y))).total)) }
        Chart(data) { p in
            let y = String(DailyChart.keyFormat.string(from: p.date).prefix(4))
            BarMark(x: .value(L("Jahr", "Year"), y), y: .value("GB", p.gb), width: .ratio(0.5))
                .cornerRadius(3)
                .foregroundStyle(Color.accentColor.opacity(y == selected ? 1 : 0.4))
                .annotation(position: .top) {
                    Text(String(format: "%.1f GB", p.gb)).font(.caption).foregroundStyle(.secondary)
                }
        }
        .chartYAxis(.hidden)
        .frame(height: 140)
    }
}

struct Tooltip: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor))
            .shadow(color: .black.opacity(0.15), radius: 4, y: 1))
    }
}

// MARK: - Einstellungen (Fenster)
struct SettingsView: View {
    @ObservedObject var prefs = Prefs.shared
    var body: some View {
        Form {
            Section {
                Picker(L("Sprache", "Language"), selection: $prefs.language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                Picker(L("Menüleiste", "Menu bar"), selection: $prefs.style) {
                    ForEach(BarStyle.allCases) { Text($0.title).tag($0) }
                }
                Toggle(L("Bei Anmeldung starten", "Launch at login"), isOn: $prefs.launchAtLogin)
                Toggle(L("iPhone-Hotspot immer anzeigen", "Always show iPhone hotspot"), isOn: $prefs.instantHotspot)
            } header: {
                Text(L("Allgemein", "General"))
            } footer: {
                Text(L("Deine iPhones und iPads mit derselben Apple-ID stehen im Menü, auch wenn ihr Hotspot aus ist. Ein Klick schaltet ihn per Bluetooth ein und verbindet – wie bei Apple.",
                       "Your iPhones and iPads with the same Apple ID appear in the menu even when their hotspot is off. One click turns it on via Bluetooth and joins – like Apple's menu."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Label(L("Ortungsdienste", "Location Services"), systemImage: "location.fill")
                    Spacer()
                    if prefs.locationGranted {
                        StatusBadge(text: L("Erlaubt", "Allowed"), ok: true)
                    } else {
                        Button(L("Erlauben …", "Allow …")) { Actions.openLocationSettings() }
                    }
                }
                HStack {
                    Label(L("Festplattenvollzugriff", "Full Disk Access"), systemImage: "internaldrive")
                    Spacer()
                    StatusBadge(text: L("Nicht nötig", "Not needed"), ok: true)
                }
            } header: {
                Text(L("Berechtigungen", "Permissions"))
            } footer: {
                Text(L("Die Ortungsdienste braucht macOS nur, um den WLAN-Namen herauszugeben – der Standort wird nie abgefragt. Wifi Usage liest nur die Netzwerkzähler des Systems und seinen eigenen Datenordner, daher ist kein Festplattenvollzugriff nötig.",
                       "macOS only reveals the Wi-Fi name to apps with Location Services – your location is never requested. Wifi Usage only reads the system's network counters and its own data folder, so no Full Disk Access is needed."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Label(L("Gespeicherte WLANs", "Saved Wi-Fi networks"), systemImage: "wifi")
                    Spacer()
                    Button(L("Öffnen …", "Open …")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")!)
                    }
                }
            } footer: {
                Text(L("Passwörter speichert macOS selbst, sobald eine Verbindung geklappt hat. Wifi Usage liest und speichert keine Passwörter.",
                       "macOS saves passwords itself once a connection works. Wifi Usage never reads or stores passwords."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("Daten", "Data")) {
                HStack {
                    Text("~/Library/Application Support/Datenmonitor")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(L("Im Finder zeigen", "Show in Finder")) {
                        NSWorkspace.shared.open(Storage.shared.dataDirectory)
                    }
                }
            }

            Section(L("Unterstützen", "Support")) {
                HStack(spacing: 12) {
                    CoffeeIcon(size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Gefällt dir Wifi Usage?", "Enjoying Wifi Usage?")).fontWeight(.semibold)
                        Text(L("Spendier mir einen Kaffee ☕", "Buy me a coffee ☕"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    CoffeeButton(compact: true)
                }
            }

            Section {
                HStack {
                    Text("Wifi Usage \(APP_VERSION)").foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Wifi Usage beenden", "Quit Wifi Usage")) { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 560)
    }
}

struct StatusBadge: View {
    let text: String
    let ok: Bool
    var body: some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .foregroundStyle(ok ? Color.green : Color.orange)
    }
}

// MARK: - Buy Me a Coffee
let COFFEE_YELLOW = Color(red: 1.0, green: 0.867, blue: 0.0)   // Markenfarbe #FFDD00

struct CoffeeIcon: View {
    let size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(COFFEE_YELLOW)
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(.black)
        }
        .frame(width: size, height: size)
    }
}

struct CoffeeButton: View {
    var compact = false
    var body: some View {
        Button {
            if let url = URL(string: COFFEE_URL) { NSWorkspace.shared.open(url) }
        } label: {
            Text(compact ? "Buy me a coffee" : "☕  Buy me a coffee")
                .font(compact ? .callout.weight(.semibold) : .headline)
                .foregroundStyle(.black)
                .padding(.horizontal, compact ? 12 : 20)
                .padding(.vertical, compact ? 5 : 9)
                .frame(maxWidth: compact ? nil : .infinity)
                .background(Capsule().fill(COFFEE_YELLOW))
        }
        .buttonStyle(.plain)
    }
}

/// Erscheint beim ersten Start einmal; jederzeit wegklickbar.
struct CoffeeView: View {
    let close: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            CoffeeIcon(size: 64).padding(.top, 8)
            Text(L("Gefällt dir Wifi Usage?", "Enjoying Wifi Usage?"))
                .font(.title2.bold())
            Text(L("Wifi Usage ist kostenlos, ohne Werbung und ohne Tracking. Wenn es dir hilft, freue ich mich über einen Kaffee.",
                   "Wifi Usage is free, with no ads and no tracking. If it helps you, I'd be happy about a coffee."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            CoffeeButton().padding(.top, 4)
            Button(L("Vielleicht später", "Maybe later"), action: close)
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
            Text(L("Erscheint nur dieses eine Mal – du findest es jederzeit in den Einstellungen.",
                   "Shown only once – you can always find it in Settings."))
                .font(.caption2).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(width: 380)
    }
}

// MARK: - Autostart (eigener launchd-Agent, wie install-widget.sh ihn anlegt)
/// Die App richtet ihren Autostart selbst ein — so klappt er auch nach `brew install`, wo die
/// Installation nicht in ~/Library schreiben darf. Wirkt ab der nächsten Anmeldung.
enum Autostart {
    static let label = "at.datenmonitor.widget"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// Pfad, der Updates überlebt: aus Homebrews versioniertem Cellar-Pfad wird der feste opt-Pfad.
    static var executablePath: String {
        let p = Bundle.main.executablePath ?? CommandLine.arguments[0]
        guard let r = p.range(of: "/Cellar/wifi-usage/[^/]+/", options: .regularExpression) else { return p }
        return p.replacingCharacters(in: r, with: "/opt/wifi-usage/")
    }

    /// Beim Start: Autostart einrichten, solange er gewünscht ist (Standard) und noch nicht auf
    /// genau diese App zeigt.
    static func setup() {
        guard Prefs.shared.launchAtLogin else { return }
        if (NSDictionary(contentsOf: plistURL)?["ProgramArguments"] as? [String])?.first != executablePath { enable() }
    }

    static func enable() {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Datenmonitor").path
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],   // nach Absturz neu starten, „Beenden" respektieren
            "ThrottleInterval": 10,
            "ProcessType": "Interactive",
            "StandardOutPath": logs + "/widget.out.log",
            "StandardErrorPath": logs + "/widget.err.log",
        ]
        do {
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: logs, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
            NSLog("Wifi Usage: Autostart eingerichtet (\(executablePath))")
        } catch {
            NSLog("Wifi Usage: Autostart nicht einrichtbar: \(error.localizedDescription)")
        }
    }

    static func disable() {
        try? FileManager.default.removeItem(at: plistURL)
        NSLog("Wifi Usage: Autostart entfernt")
    }
}

// MARK: - Log (widget.err.log): nur die letzten 90 Tage
/// Das Log zeigt, was die App getan hat (Starts, WLAN-Wechsel, Fehler) — mit WLAN-Namen, also
/// privat. Einträge älter als 90 Tage werden gelöscht. Die Datei wird an Ort und Stelle gekürzt,
/// weil launchd sie offen hält und weiter hineinschreibt.
enum Log {
    static let keepDays = 90

    static func prune() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Datenmonitor/widget.err.log")
        guard let h = try? FileHandle(forUpdating: url), let data = try? h.readToEnd() else { return }
        let text = String(decoding: data, as: UTF8.self)   // auch bei kaputten Bytes kürzen
        defer { try? h.close() }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        let cutoff = f.string(from: Date().addingTimeInterval(-Double(keepDays) * 86_400))
        var keep = true   // Zeilen ohne Datum (Fortsetzungen) folgen der Zeile davor
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let day = line.prefix(10)
            if day.count == 10, f.date(from: String(day)) != nil { keep = day >= cutoff }
            return keep
        }.joined(separator: "\n")
        guard kept.utf8.count < data.count else { return }   // nichts zu löschen
        try? h.truncate(atOffset: 0)
        try? h.write(contentsOf: Data(kept.utf8))
    }
}

// MARK: - Start
// Nur eine Instanz: läuft Wifi Usage schon (z. B. per Autostart), still beenden. Kurz warten,
// falls die alte gerade beendet wird (Neuinstallation, Update).
func otherInstanceRunning() -> Bool {
    NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? Autostart.label)
        .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
}
for _ in 0..<10 where otherInstanceRunning() { Thread.sleep(forTimeInterval: 0.5) }
if otherInstanceRunning() { exit(0) }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AppController()
app.delegate = controller
app.run()
