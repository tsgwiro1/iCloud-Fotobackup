#!/bin/bash
#
# fotostatus.sh – Momentaufnahme eines laufenden Exports.
# In einem zweiten Terminalfenster aufrufen, der Export läuft ungestört weiter.
#
#   ./fotostatus.sh          einmalige Anzeige
#   ./fotostatus.sh -w       aktualisiert sich alle 60 Sekunden
#
# Braucht einen SSH-Zugang zum Zielrechner ohne Passwortabfrage. Ohne ihn
# funktioniert alles ausser der Zeile "Am Ziel".

set -u

HIER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KONFIG=""
for K in "$HIER/config" "$HIER/../config" "$HOME/.config/fotobackup/config"; do
  if [ -f "$K" ]; then KONFIG="$K"; break; fi
done
if [ -z "$KONFIG" ]; then
  echo "FEHLER: keine Konfigurationsdatei gefunden." >&2
  echo "Vorlage kopieren: cp config.example config" >&2
  exit 2
fi
# shellcheck source=/dev/null
. "$KONFIG"

: "${SERVER:?SERVER fehlt in der Konfiguration}"
: "${BESTAND:?BESTAND fehlt in der Konfiguration}"
SSH_USER="${SSH_USER:-${SMB_USER:-}}"

LOG="$HOME/Library/Logs/fotoexport/export_$(date +%F).log"
EXPORTDB="${EXPORTDB:-$HOME/Library/Application Support/fotoexport/osxphotos_export.db}"

# Zahl der Objekte in der Mediathek – aus der Exportdatenbank, damit die
# Fortschrittsanzeige nicht auf einer gepflegten Konstante beruht.
gesamt_objekte() {
  [ -f "$EXPORTDB" ] || return
  sqlite3 "$EXPORTDB" "SELECT count(*) FROM photoinfo;" 2>/dev/null
}

anzeigen() {
  echo "───────────────────────────────────────────────"
  echo " Fotoexport – Stand $(date '+%H:%M:%S')"
  echo "───────────────────────────────────────────────"

  if pgrep -f "osxphotos export" > /dev/null; then
    echo " Status        läuft"
  else
    echo " Status        kein Export aktiv"
  fi

  echo " Mac frei      $(/bin/df -g / | awk 'NR==2 {print $4}') GB"

  if [ -f "$EXPORTDB" ]; then
    echo " Exportdb      $(/usr/bin/du -h "$EXPORTDB" | cut -f1)"
  fi

  # Auf dem Zielrechner zählen, nicht über den SMB-Mount – das ist um Längen
  # schneller und stört den laufenden Export nicht.
  ZAHLEN=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "${SSH_USER}@${SERVER}" \
    "find '$BESTAND' -type f ! -name '*.xmp' ! -path '*/_berichte/*' ! -path '*/_geloescht/*' | wc -l; du -sh '$BESTAND' | cut -f1" 2>/dev/null)

  if [ -n "$ZAHLEN" ]; then
    DATEIEN=$(echo "$ZAHLEN" | sed -n 1p | tr -d ' ')
    GROESSE=$(echo "$ZAHLEN" | sed -n 2p)
    echo " Am Ziel       $DATEIEN Dateien, $GROESSE"

    GESAMT="$(gesamt_objekte)"
    if [ -n "${GESAMT:-}" ] && [ "$GESAMT" -gt 0 ] 2>/dev/null; then
      echo " Fortschritt   rund $(( DATEIEN * 100 / GESAMT )) % von $GESAMT Objekten"
    fi
  else
    echo " Am Ziel       nicht erreichbar"
  fi

  echo
  echo " Letzte Zeilen aus dem Log:"
  tail -3 "$LOG" 2>/dev/null | sed 's/^/   /'
  echo
}

if [ "${1:-}" = "-w" ]; then
  while true; do clear; anzeigen; sleep 60; done
else
  anzeigen
fi
