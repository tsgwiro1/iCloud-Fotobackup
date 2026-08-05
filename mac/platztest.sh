#!/bin/bash
#
# platztest.sh – prüft, ob macOS den als "löschbar" geführten Speicher der
# Fotomediathek tatsächlich freigibt, wenn der Platz knapp wird.
#
# Legt Platzhalterdateien in 10-GB-Schritten an und misst nach jedem Schritt.
# Bricht bei Unterschreiten der Notgrenze ab. Die Platzhalter werden in jedem
# Fall wieder gelöscht – auch bei Ctrl-C oder Fehler.

set -u

ORDNER="$HOME/.platztest"
SCHRITT_GB=10
NOTGRENZE_GB=4
MAX_SCHRITTE=5

frei_gb() { /bin/df -g / | awk 'NR==2 {print $4}'; }

aufraeumen() {
  echo
  echo "Aufräumen..."
  /bin/rm -rf "$ORDNER"
  sleep 3
  echo "Platzhalter entfernt. Verfügbar: $(frei_gb) GB"
}
trap aufraeumen EXIT INT TERM

mkdir -p "$ORDNER"
START="$(frei_gb)"
echo "Start: $START GB verfügbar. Notgrenze $NOTGRENZE_GB GB."
echo

for i in $(seq 1 $MAX_SCHRITTE); do
  VOR="$(frei_gb)"

  if [ "$VOR" -lt "$(( NOTGRENZE_GB + SCHRITT_GB ))" ]; then
    echo "Nächster Schritt würde die Notgrenze reissen. Test endet hier."
    break
  fi

  /bin/dd if=/dev/zero of="$ORDNER/teil_$i.bin" bs=1m count=$(( SCHRITT_GB * 1024 )) 2>/dev/null
  sleep 5
  NACH="$(frei_gb)"
  BELEGT=$(( i * SCHRITT_GB ))
  ERWARTET=$(( START - BELEGT ))

  printf "Schritt %d  belegt %2d GB   verfügbar %2d GB   erwartet %2d GB" \
         "$i" "$BELEGT" "$NACH" "$ERWARTET"

  if [ "$NACH" -gt "$(( ERWARTET + 5 ))" ]; then
    echo "   ← macOS hat nachgeschoben"
  else
    echo "   ← keine Freigabe"
  fi

  if [ "$NACH" -lt "$NOTGRENZE_GB" ]; then
    echo "NOTGRENZE unterschritten. Abbruch."
    break
  fi
done

echo
echo "Nachbeobachtung, 60 Sekunden:"
for i in 1 2 3 4; do
  echo "  $(date +%H:%M:%S)  verfügbar: $(frei_gb) GB"
  sleep 15
done
