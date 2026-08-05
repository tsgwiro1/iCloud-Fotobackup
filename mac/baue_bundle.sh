#!/bin/bash
#
# baue_bundle.sh – erzeugt eine App-Hülle für den geplanten Export.
#
# Warum das nötig ist:
#
# macOS vergibt den Zugriff auf Netzwerkvolumes pro Programm. Ein Skript, das
# unter launchd läuft, bekommt dafür keinen Dialog – es scheitert still mit
# "Operation not permitted". Und einem nackten Programm ohne App-Bundle lässt
# sich Festplattenvollzugriff gar nicht erteilen; diese Berechtigung ist für
# Bundles gedacht.
#
# Die Alternative wäre, /bin/bash freizugeben. Dann hätte aber jedes
# Bash-Skript auf dem Rechner vollen Zugriff – auch jedes, das man künftig aus
# Versehen ausführt. Eine eigene Hülle beschränkt die Berechtigung auf dieses
# eine Vorhaben und erscheint in den Systemeinstellungen mit eigenem Namen.
#
# Das Applet schluckt Fehler bewusst: Ein AppleScript-Applet zeigt sonst einen
# Dialog, und ein Hintergrundlauf, der auf einen Klick wartet, hängt für immer.
# Der Rückgabewert steht ohnehin im Protokoll des Exportskripts.
#
# Aufruf:  ./baue_bundle.sh
# Danach:  Bundle in Systemeinstellungen → Datenschutz & Sicherheit →
#          Festplattenvollzugriff hinzufügen und aktivieren.

set -eu

HIER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKRIPT="$HIER/fotoexport.sh"
ZIEL="${1:-$HOME/Applications/Fotobackup.app}"

if [ ! -x "$SKRIPT" ]; then
  echo "FEHLER: $SKRIPT nicht gefunden oder nicht ausführbar." >&2
  exit 1
fi

NAME="$(basename "$ZIEL" .app)"

mkdir -p "$(dirname "$ZIEL")"
rm -rf "$ZIEL"

osacompile -o "$ZIEL" << EOF
on run
    try
        do shell script "'$SKRIPT' --geplant"
    on error
        -- Absichtlich still. Was schiefging, steht im Protokoll unter
        -- ~/Library/Logs/fotoexport/ und wird von pruefe_umgebung.sh gelesen.
    end try
end run
EOF

# Das Programm im Bundle heisst nach dem Übersetzen "applet". Unter diesem
# Namen fragt macOS später nach Berechtigungen – und ein Dialog, in dem
# "applet" um Zugriff auf die Fotomediathek bittet, sieht aus wie etwas, das
# man wegklicken sollte. Deshalb wird es umbenannt.
mv "$ZIEL/Contents/MacOS/applet" "$ZIEL/Contents/MacOS/$NAME"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $NAME" \
                        "$ZIEL/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $NAME" \
                        "$ZIEL/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleName string $NAME" \
                             "$ZIEL/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string local.$(echo "$NAME" | tr 'A-Z' 'a-z')" \
                        "$ZIEL/Contents/Info.plist" 2>/dev/null || true

# Nach der Änderung neu signieren, sonst hält macOS das Bundle für beschädigt
codesign --force --sign - "$ZIEL" 2>/dev/null

echo "Bundle gebaut: $ZIEL"
echo "Programmname in den Dialogen: $NAME"
echo
echo "Noch zu tun:"
echo
echo "1. Berechtigung erteilen"
echo "     Systemeinstellungen → Datenschutz & Sicherheit → Festplattenvollzugriff"
echo "     '+' anklicken, dann ⌘⇧G und diesen Pfad eingeben:"
echo "     $ZIEL"
echo "     Hinzufügen und den Schalter aktivieren."
echo
echo "2. Auftragsdatei auf das Bundle umstellen"
echo "     In ~/Library/LaunchAgents/local.fotobackup.export.plist muss unter"
echo "     ProgramArguments stehen:"
echo "     $ZIEL/Contents/MacOS/$NAME"
echo
echo "3. Neu laden und ausprobieren"
echo "     launchctl bootout gui/\$(id -u)/local.fotobackup.export"
echo "     launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/local.fotobackup.export.plist"
echo "     launchctl kickstart -k gui/\$(id -u)/local.fotobackup.export"
echo
echo "4. Ergebnis prüfen"
echo "     ./mac/pruefe_umgebung.sh"
