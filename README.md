# Datenmonitor-Widget für macOS

Ein winziges Menüleisten-Widget im **Stats-Stil**: unten der Datenverbrauch (GB) des
aktuellen WLANs im laufenden Monat, darüber klein der Netz-Name. Klick öffnet ein Menü
mit allen Netzen des Monats und ein Untermenü für frühere Monate.

Ein einziges Swift-File, kompiliert mit Apples `swiftc`. Keine Fremdsoftware, kein
SwiftBar/xbar, kein Netzwerkzugriff, keine Telemetrie. Daten rein lokal unter
`~/Library/Application Support/Datenmonitor/usage.json`.

## Dateien

- `DatenmonitorWidget.swift` — kompletter Quellcode (Widget **und** Tracker in einem)
- `install-widget.sh` — kompiliert **einmal** und richtet den Autostart ein
- `at.datenmonitor.widget.plist` — launchd-Vorlage (Autostart nach Login)

## Installation

Alle drei Dateien in denselben Ordner legen, dann im Terminal:

```bash
chmod +x install-widget.sh
./install-widget.sh
```

Das übersetzt das Widget nach `~/.local/bin/datenmonitor-widget`, lädt den launchd-Agent
und startet das Widget. Es erscheint oben rechts in der Menüleiste und startet künftig
automatisch nach dem Login — **ohne erneutes Kompilieren**. `swiftc` läuft nur beim
Ausführen des Install-Skripts, nicht bei jedem Start.

**Voraussetzung:** Apples Command Line Tools (liefern `swiftc`). Falls nicht vorhanden:

```bash
xcode-select --install
```

## Update (neuer Code)

Neuen Code in `DatenmonitorWidget.swift` einfügen, dann `./install-widget.sh`.
Wenn der Autostart schon läuft und `bootstrap` mit „Input/output error" abbricht, die
laufende Version einfach neu starten:

```bash
launchctl kickstart -k gui/$(id -u)/at.datenmonitor.widget
```

## Bedienung

Menüleiste: obere Zeile = aktuelles Netz, untere Zeile = Verbrauch diesen Monat.
Über dem Limit (10 GB) wird die Zahl rot. Die Farbe passt sich sonst automatisch an
die Menüleiste an (dunkel bei heller Leiste, hell bei dunkler).

Klick öffnet:

```
Aktuelles WLAN: iPhone-Hotspot
   4.70 GB   (↓ 4.10 GB  ↑ 0.60 GB)
──────────────
Diesen Monat (September 2026):
 ✓ iPhone-Hotspot — 4.70 GB
   FRITZ!Box 7590 — 8.40 GB
──────────────
Frühere Monate ▸
──────────────
Jetzt aktualisieren
Datenordner öffnen
Beenden
```

Der Haken (✓) markiert das Netz, in dem du gerade bist.

## Wie es zählt

Alle 20 Sekunden liest das Widget die kumulativen Byte-Zähler der WLAN-Schnittstelle
(`netstat -ibn`, Link-Layer-Zeile, IPv4+IPv6 zusammen), bildet die Differenz zur letzten
Messung und schreibt sie dem aktuellen Netz im aktuellen Monat gut.

**Netz-Erkennung ohne Standort-Berechtigung** (der Kernpunkt): Seit macOS 14.4 gibt das
System den WLAN-**Namen** (SSID) nur an Apps mit Ortungsdienste-Zugriff heraus. Ein
unsigniertes Terminal-Programm bekommt den nicht. Deshalb wird jedes Netz stattdessen
über die **MAC-Adresse seines Routers** (via `arp`) eindeutig identifiziert — das ist
immer lesbar. Der **Anzeigename** ist die echte SSID, falls verfügbar, sonst eine
Heuristik: Gateway `172.20.10.x` → „iPhone-Hotspot", `192.168.43.1` → „Android-Hotspot",
sonst „WLAN ·<MAC-Ende>".

- **Neustart/Reboot:** Der Roh-Zähler springt zurück; das wird erkannt (kein Fehlzählen).
- **Monatswechsel:** automatisch, alte Monate bleiben im Untermenü einsehbar.
- **Kein WLAN:** wird nicht gezählt.

## Anpassen (im Quellcode, oben in der Datei)

- `LIMIT_GB` — Monatslimit (Standard 10).
- `SAMPLE_INTERVAL` — Messintervall in Sekunden (Standard 20).

In `renderTwoLine`:

- Schriftgröße: die Zahlen hinter `ofSize:` (obere Zeile / untere Zeile).
- Dicke: `weight:` (`.regular`, `.medium`, `.semibold`, `.bold`).
- Farbe: `topColor` / `botColor`. `img.isTemplate = !warn` lässt die Farbe automatisch der
  Menüleiste folgen; für eine feste eigene Farbe `isTemplate` auf `false` setzen und in
  `topColor`/`botColor` z. B. `NSColor(calibratedRed:green:blue:alpha:)` verwenden.

## Bekannte Einschränkungen

- **WLAN-Name:** Ohne Ortungsdienste-Freigabe zeigt macOS die SSID nicht; dann greift die
  Heuristik/MAC-Bezeichnung. Für echte SSID-Namen wäre eine signierte `.app` mit
  Standort-Berechtigung nötig (bewusst nicht umgesetzt, um ohne Berechtigung auszukommen).
- **Hotspot vs. WLAN:** über Router/SSID unterschieden; zwei Netze mit identischem Router
  lassen sich nicht trennen.
- **Genauigkeit:** Interface-Zähler erfassen allen Verkehr auf der Leitung (inkl. Overhead);
  der Providerwert kann um wenige Prozent abweichen.
- **GiB:** gerechnet wie im Finder (1 GB = 1 073 741 824 Byte).

## Zusammenspiel mit LuLu

Das Widget zählt nur und öffnet keine Verbindungen (LuLu fragt also nie nach). LuLu bleibt
für die Kontrolle ausgehender Verbindungen zuständig, das Widget zeigt den Verbrauch.

## Entfernen

```bash
launchctl bootout gui/$(id -u)/at.datenmonitor.widget
rm ~/.local/bin/datenmonitor-widget
rm ~/Library/LaunchAgents/at.datenmonitor.widget.plist
rm -rf ~/Library/Application\ Support/Datenmonitor   # optional: Daten löschen
```