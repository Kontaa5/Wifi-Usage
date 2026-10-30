# AGENTS.md – Anleitung für KI-Assistenten

Lies das zuerst. Gilt für jede KI (Claude, Codex, Cursor, Copilot …), die in diesem Ordner arbeitet.

## Wie Gabriel arbeiten will

- **Antworten kurz, auf Deutsch, in Stichworten.** Technisch vollständig, aber kein Füllstoff. Selbstverständliches („gefunden“, „gepusht“) einmal sagen, fertig. Details nur auf Nachfrage.
- **Bei Aufgaben als Checkliste berichten**, auch zwischendurch:
  - 🔄 mache gerade
  - ✅ erledigt (und wie geprüft)
  - ⚠️ Problem – mit Ursache
  - ⏳ offen / brauche dich
  - 🔒 Security – nach jeder Code-Änderung: was geprüft, was offen
- **Nie „geht nicht“ ohne Prozentzahl.** Erst testen, dann behaupten. Sonst: „70 % sicher, weil …“ + wie man es prüft. (Frühere KI hat fälschlich behauptet, Instant Hotspot und Verbinden mit bekannten WLANs seien für Fremd-Apps unmöglich – beides ging.)
- **Kein „AI slop“**: nichts als „OK“ melden, ohne die Ausgabe wirklich angesehen zu haben. Fehler offen zugeben.
- **Security ist extrem wichtig.** Fremde Daten nie ungeprüft in HTML, Shell, SQL, Formatstrings. Prozesse nur mit Argument-Array und absoluten Pfaden.
- **Schlüsselbund, Passwörter, Systemeinstellungen nie anfassen** – auch keine Abfrage, die ein Keychain-/Passwort-Popup auslöst. Bei Workarounds stoppen und fragen.
- **Keine SSH-/Remote-Befehle von selbst** (`ssh`, `git ls-remote`, `fetch`/`pull` per SSH) – jeder Zugriff löst Secretive/Touch ID aus. Prüfen nur über öffentliches HTTPS.
- **Git:** committen ohne zu fragen, direkt auf `main`, nie `.DS_Store` stagen. Commits sind unsigniert (global `commit.gpgsign false`, `tag.gpgsign false`) – nur der Push fragt Touch ID. **Pushen nur, wenn Gabriel es sagt** – einmal, ohne Zusatzprüfungen.
- Gründliche Audits: eigener Skill `insurance-security` (in `~/.claude/skills/`, falls vorhanden) – Security- + Rechts-Prüfliste, beheben, mit bösem Input gegenprüfen.

## Was das Projekt ist

**Wifi Usage** – macOS-Menüleisten-App (Swift, ohne Xcode-Projekt, nur `swiftc`). Zeigt Datenverbrauch pro WLAN mit Statistik, wechselt WLANs aus dem Menü, verbindet sich mit dem iPhone-Hotspot.

| Datei | Zweck |
|---|---|
| `WifiUsage.swift` | gesamter Code (~2700 Zeilen) |
| `build-app.sh` | baut die `.app`; `VERSION`/`BUILD` hier hochzählen. `--dev` = Entwicklungs-Signatur |
| `install-widget.sh` | lokal bauen (`--dev`) + LaunchAgent `at.datenmonitor.widget` laden |
| `at.datenmonitor.widget.plist` | LaunchAgent (KeepAlive nur bei Absturz) |
| `Formula/wifi-usage.rb` | Homebrew-Formel, gepinnt auf Tag **und** Commit-SHA |
| `tools/make-icon.swift` | erzeugt `AppIcon.icns` (eigenes Icon) |
| `docs/screenshots/` | aus aktuellem Code erzeugt, keine echten Netznamen |
| `LICENSE.md` | PolyForm Noncommercial 1.0.0 – ansehen/ändern ja, verkaufen nein |

Repo: `github.com/Kontaa5/Wifi-Usage` (alter Name `WLAN-Consumption-Mac-Widget` leitet weiter; lokales Remote zeigt noch auf den alten Namen, funktioniert).

## Getroffene Entscheidungen (nicht wieder aufrollen)

- **Passwörter: macOS speichert, die App liest und speichert nichts.** Kein eigener Tresor, kein Keychain-Zugriff. Bekannte Netze: privates CoreWiFi `knownNetworkProfiles` + `associate` mit Profil. Neues Netz: Passwort-Dialog → CoreWLAN `associate(to:password:)`, Passwort nur im Speicher; macOS merkt es sich (`rememberJoinedNetworks`).
- **iPhone-Hotspot immer anzeigen** (Einstellung): privates `Sharing.framework` `SFRemoteHotspotSession` weckt den Hotspot per Bluetooth wie Apples Instant Hotspot (~8–10 s). Während eines Wechsels kein Menü-Scan (blockiert sonst den WLAN-Chip, „Resource busy“). Akkuanzeige entfernt (lieferte immer 75 %).
- **Evil-Twin-Schutz:** bei gesichertem Profil werden offene Netze gleichen Namens ignoriert.
- **Umbenannte Netze:** gleiche BSSID + neuer Name → Statistik wird zusammengeführt, ab dann neuer Name. Nutzer können in der App nicht umbenennen.
- **Private APIs** vor jedem Aufruf mit `responds(to:)` prüfen; `NSError**` als `AutoreleasingUnsafeMutablePointer` (sonst Absturz durch Doppel-Release).
- **Signatur:** ad hoc + Hardened Runtime. Release (Homebrew) an cdhash gebunden → macOS fragt nach jedem Update einmal neu nach Ortungsdiensten (nötig für den WLAN-Namen). `--dev` bindet nur an die Bundle-ID → keine Abfrage bei jedem Neubau.
- **Autostart macht die App selbst** (Einstellung „Bei Anmeldung starten“, schreibt den LaunchAgent; Cellar-Pfad → opt-Pfad).
- **Log:** `~/Library/Logs/…` wird nach 90 Tagen rollend gekürzt (beim Start + täglich, in place – launchd öffnet im Append-Modus).
- **Kaputte `usage.json`** wird gesichert (`usage.unlesbar-<Datum>.json`), nicht überschrieben.
- **Homebrew direkt aus dem Haupt-Repo**, kein eigenes Tap-Repo:
  ```
  brew tap kontaa5/wifi-usage https://github.com/Kontaa5/Wifi-Usage
  brew install kontaa5/wifi-usage/wifi-usage
  ```
  Voll qualifizierter Name nötig (Homebrew 7 „untrusted tap“).
- Single-Instance-Schutz, keine Netzwerkaufrufe, keine Telemetrie – keine Daten verlassen das Gerät.

## Release-Ablauf

1. Code ändern, `VERSION`/`BUILD` in `build-app.sh` erhöhen.
2. `./install-widget.sh` → lokal testen (läuft danach als LaunchAgent).
3. Commit „Wifi Usage X.Y: …“, Tag `vX.Y`.
4. Formel: `tag:` + `revision:` (SHA des Release-Commits) setzen, eigener Commit „Formel: wifi-usage X.Y“.
5. Push nur auf Gabriels Ansage: `git push origin main vX.Y`.
6. Danach Brew-Installation über HTTPS testen (tap, install, `wifi-usage` startet, uninstall, untap).

## Verlauf (Kurzfassung)

- bis 2.8: Statistik, WLAN-Wechsel, Einstellungen, eigener Passwort-Tresor (Keychain) → ständige Keychain-Popups.
- 2.9: Tresor entfernt, Wechsel über macOS-Profile, Instant Hotspot, Umbenennungs-Erkennung, Lizenz PolyForm, Hardened Runtime.
- 2.9.x: Security-Audits, Absturz-Fix CoreWiFi, Akkuanzeige raus, Log-Aufbewahrung 90 Tage, Dev-/Release-Signatur.
- 2.10: Audit mit `insurance-security` – Evil-Twin-Schutz, eigenes Icon, Datenschutz-Abschnitt im README.
- 2.10.1: Aufräumen (toter Code, alte Handoff-Datei, `.DS_Store`), Screenshots neu.

## Offen / nur Gabriel

- Alte Keychain-Einträge „Datenmonitor – WLAN-Zugangsdaten“ / „Wifi Usage – WLAN-Zugangsdaten“ selbst löschen.
- Buy Me a Coffee: ohne verbundene Auszahlung kein Bezahlknopf → Spenden-Interesse erst messbar, wenn verbunden.
- Optional: GitHub „Keep my email addresses private“.
