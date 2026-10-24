#!/bin/bash
#
# install-widget.sh — Kompiliert und installiert das Wifi-Usage-Menüleisten-Widget.
# Nur Apple-Bordmittel (swiftc aus den Xcode Command Line Tools). Keine Fremdpakete.
#
set -eu

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/Wifi Usage.app"
OLD_APP="$HOME/Applications/Datenmonitor.app"   # Name bis 2.3
AGENT_DIR="$HOME/Library/LaunchAgents"
SUPPORT_DIR="$HOME/Library/Application Support/Datenmonitor"
PLIST="at.datenmonitor.widget.plist"

echo "== Wifi Usage: Installation =="

# 1. App bauen (Compiler-Prüfung, Info.plist und Signatur stehen in build-app.sh)
mkdir -p "$SUPPORT_DIR"
"$SRC_DIR/build-app.sh" "$APP" --dev   # Entwickler-Build: Ortungsfreigabe bleibt über Neubauten
echo "Installiert: $APP"

# Alte Versionen aufräumen (ohne .app bzw. unter dem alten Namen „Datenmonitor")
rm -f "$HOME/.local/bin/datenmonitor-widget"
rm -rf "$OLD_APP"

# 2. launchd-Agent mit echtem Home-Pfad
mkdir -p "$AGENT_DIR"
sed "s|__HOME__|$HOME|g" "$SRC_DIR/$PLIST" > "$AGENT_DIR/$PLIST"

# 3. Laden (bei Bedarf erst entladen)
launchctl bootout "gui/$(id -u)/at.datenmonitor.widget" 2>/dev/null || true
# bootout ist asynchron — bootstrap direkt danach scheitert sonst mit "Input/output error".
for i in 1 2 3 4 5; do
  launchctl bootstrap "gui/$(id -u)" "$AGENT_DIR/$PLIST" 2>/dev/null && break
  [ "$i" = 5 ] && { echo "Fehler: launchctl bootstrap fehlgeschlagen."; exit 1; }
  sleep 1
done

echo ""
echo "Fertig. Das Widget erscheint jetzt oben rechts in der Menüleiste."
echo ""
echo "Beim ersten Start fragt macOS nach den Ortungsdiensten: bitte erlauben,"
echo "sonst bleibt der echte WLAN-Name verborgen. Nachträglich unter"
echo "Systemeinstellungen → Datenschutz & Sicherheit → Ortungsdienste → Wifi Usage."
echo ""
echo "Beenden/entfernen:  launchctl bootout gui/$(id -u)/at.datenmonitor.widget"
