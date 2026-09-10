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
