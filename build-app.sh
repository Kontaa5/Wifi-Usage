#!/bin/bash
#
# build-app.sh — Baut „Wifi Usage.app“ an den angegebenen Ort. Genutzt von install-widget.sh
# und der Homebrew-Formel. Nur Apple-Bordmittel (swiftc aus den Xcode Command Line Tools).
#
#   ./build-app.sh "$HOME/Applications/Wifi Usage.app"
#
set -eu

VERSION="2.9.2"
BUILD="16"

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="${1:?Ziel angeben, z. B. ./build-app.sh \"\$HOME/Applications/Wifi Usage.app\"}"
BIN="wifi-usage"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "Fehler: 'swiftc' fehlt. Bitte einmalig die Xcode Command Line Tools installieren:"
  echo "    xcode-select --install"
  exit 1
fi

# Als kleine .app bauen: nur eine App mit Bundle-ID darf Ortungsdienste nutzen,
# und ohne die gibt macOS den WLAN-Namen (SSID) nicht heraus.
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SRC_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"   # App-Icon: WLAN-Symbol, transparent
echo "Kompiliere ..."
swiftc -O -o "$APP/Contents/MacOS/$BIN" "$SRC_DIR/WifiUsage.swift" \
  -framework AppKit -framework SwiftUI -framework Charts -framework CoreWLAN -framework CoreLocation
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>           <string>at.datenmonitor.widget</string>
    <key>CFBundleName</key>                 <string>Wifi Usage</string>
    <key>CFBundleDisplayName</key>          <string>Wifi Usage</string>
    <key>CFBundleExecutable</key>           <string>$BIN</string>
    <key>CFBundleIconFile</key>             <string>AppIcon</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>$VERSION</string>
    <key>CFBundleVersion</key>              <string>$BUILD</string>
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
# bleibt so über Neubauten und Updates erhalten. Den eigenen Schlüsselbund-Eintrag bindet macOS
# dagegen an genau diese Programmversion; Wifi Usage fragt dann nicht nach, sondern verbindet über
# Apples Profile. Hardened Runtime: verhindert, dass fremder Code in die App eingeschleust wird
# (DYLD_INSERT_LIBRARIES) und so ohne Rückfrage auf ihren Schlüsselbund-Eintrag zugreift.
codesign --force --sign - --options runtime --requirements '=designated => identifier "at.datenmonitor.widget"' "$APP"
echo "Gebaut: $APP (Version $VERSION)"
