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
BIN="wifi-usage"

echo "== Wifi Usage: Installation =="

# 0. Swift-Compiler vorhanden?
if ! command -v swiftc >/dev/null 2>&1; then
  echo "Fehler: 'swiftc' fehlt. Bitte einmalig die Xcode Command Line Tools installieren:"
  echo "    xcode-select --install"
  echo "Danach dieses Skript erneut ausführen."
  exit 1
fi

# 1. Als kleine .app bauen: nur eine App mit Bundle-ID darf Ortungsdienste nutzen,
#    und ohne die gibt macOS den WLAN-Namen (SSID) nicht heraus.
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$SUPPORT_DIR"
cp "$SRC_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"   # App-Icon: WLAN-Symbol, transparent
echo "Kompiliere ..."
swiftc -O -o "$APP/Contents/MacOS/$BIN" "$SRC_DIR/WifiUsage.swift" \
  -framework AppKit -framework SwiftUI -framework Charts -framework CoreWLAN -framework CoreLocation
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>           <string>at.datenmonitor.widget</string>
    <key>CFBundleName</key>                 <string>Wifi Usage</string>
    <key>CFBundleDisplayName</key>          <string>Wifi Usage</string>
    <key>CFBundleExecutable</key>           <string>wifi-usage</string>
    <key>CFBundleIconFile</key>             <string>AppIcon</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>2.4</string>
    <key>CFBundleVersion</key>              <string>6</string>
    <key>LSMinimumSystemVersion</key>       <string>13.0</string>
    <key>LSUIElement</key>                  <true/>
    <key>NSLocationUsageDescription</key>
    <string>macOS gibt den Namen des WLANs nur mit Ortungsdienste-Freigabe heraus. Der Standort selbst wird nicht verwendet.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>macOS gibt den Namen des WLANs nur mit Ortungsdienste-Freigabe heraus. Der Standort selbst wird nicht verwendet.</string>
</dict>
</plist>
PLIST
# Ad-hoc-Signatur mit fester Anforderung (nur Bundle-ID): Die Ortungsdienste-Freigabe (= WLAN-Name)
# bleibt so über Neubauten erhalten. Gespeicherte WLAN-Passwörter bindet der Schlüsselbund dagegen
# an genau diese Programmversion (am sichersten) — nach einem Update fragt macOS deshalb einmal
# pro gespeichertem Netz nach („Immer erlauben").
codesign --force --sign - --requirements '=designated => identifier "at.datenmonitor.widget"' "$APP"
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
