#!/bin/bash
#
# fotoexport.sh – exportiert die Apple-Fotomediathek als normale Dateien auf
# einen Linux-Server.
#
# Baut die SMB-Verbindung selbst auf und am Ende wieder ab. Es bleibt kein
# Mount stehen – auch nicht, wenn der Export abbricht oder abgebrochen wird.
# Ein stehender SMB-Mount überlebt den Ruhezustand eines MacBooks nicht:
# Nach dem Aufwachen zeigt der Mountpoint auf eine tote Verbindung, jeder
# Zugriff darauf hängt, und der Finder friert mit ein.
#
# Alle rechnerspezifischen Werte stehen in der Datei "config" neben diesem
# Skript oder eine Ebene darüber. Vorlage: config.example
#
# Aufruf:
#   ./fotoexport.sh                  normaler Lauf, alles
#   ./fotoexport.sh --album "Test"   Testlauf über ein einzelnes Album
#   ./fotoexport.sh --dry-run        zeigt nur, was passieren würde
#   ./fotoexport.sh --geplant        für launchd: läuft nur im erreichbaren
#                                    Heimnetz und – sofern NETZTEIL_NOETIG=ja –
#                                    nur am Netzteil. Sonst wird der Lauf still
#                                    ausgelassen (Rückgabewert 0)
#   ./fotoexport.sh --status         Auskunft: läuft gerade einer und wie weit
#                                    ist er, wie ging der letzte aus, und darf
#                                    der nächste geplante überhaupt. Ändert
#                                    nichts und stört einen laufenden Export
#                                    nicht
#   ./fotoexport.sh --status -w      dasselbe, aktualisiert sich alle 60 s

set -u
set -o pipefail

# ---------------------------------------------------------------------------
# Konfiguration
# ---------------------------------------------------------------------------
HIER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KONFIG=""
for K in "$HIER/config" "$HIER/../config" "$HOME/.config/fotobackup/config"; do
  if [ -f "$K" ]; then KONFIG="$K"; break; fi
done
if [ -z "$KONFIG" ]; then
  echo "FEHLER: keine Konfigurationsdatei gefunden. Gesucht in:" >&2
  echo "  $HIER/config" >&2
  echo "  $HIER/../config" >&2
  echo "  $HOME/.config/fotobackup/config" >&2
  echo "Vorlage kopieren: cp config.example config" >&2
  exit 2
fi
# shellcheck source=/dev/null
. "$KONFIG"

: "${SERVER:?SERVER fehlt in der Konfiguration}"
: "${SHARE:?SHARE fehlt in der Konfiguration}"
: "${SMB_USER:?SMB_USER fehlt in der Konfiguration}"
: "${MOUNTPOINT:?MOUNTPOINT fehlt in der Konfiguration}"

OSXPHOTOS="${OSXPHOTOS:-$HOME/.local/bin/osxphotos}"
EXPORTDB="${EXPORTDB:-$HOME/Library/Application Support/fotoexport/osxphotos_export.db}"
MINDESTFREI_GB="${MINDESTFREI_GB:-8}"
KEYCHAIN_DIENST="${KEYCHAIN_DIENST:-fotobackup}"
NETZTEIL_NOETIG="${NETZTEIL_NOETIG:-ja}"

LOGVERZEICHNIS="$HOME/Library/Logs/fotoexport"
LOCKDATEI="/tmp/fotoexport.lock"

# Merker für den letzten erfolgreichen Volllauf. Nötig, weil geplante Läufe
# häufig ausgelassen werden (Akku, fremdes Netz) und deshalb oft nachgefragt
# werden muss, statt einmal am Tag.
STEMPEL="$(dirname "$EXPORTDB")/letzter_lauf"
MINDESTABSTAND_STUNDEN="${MINDESTABSTAND_STUNDEN:-20}"

DATUM="$(date +%F)"
LOG="$LOGVERZEICHNIS/export_$DATUM.log"

ALBUM=""
DRY_RUN=0
GEPLANT=0
STATUS=0
WATCH=0

while [ $# -gt 0 ]; do
  case "$1" in
    --album)    ALBUM="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --geplant)  GEPLANT=1; shift ;;
    --status)   STATUS=1; shift ;;
    -w|--watch) WATCH=1; shift ;;
    *) echo "Unbekannte Option: $1"; exit 2 ;;
  esac
done

mkdir -p "$LOGVERZEICHNIS" "$(dirname "$EXPORTDB")"

melde() { echo "$(date '+%H:%M:%S')  $*" | tee -a "$LOG"; }

# Freier Platz auf der Systemplatte in GB
frei_gb() { /bin/df -g / | awk 'NR==2 {print $4}'; }

# ---------------------------------------------------------------------------
# --status – Auskunft ohne Nebenwirkungen
# ---------------------------------------------------------------------------
# Schreibt bewusst nichts ins Protokoll und nimmt die Sperrdatei nicht. Steht
# deshalb vor der Sperrlogik und vor dem trap: --status darf einen laufenden
# Export unter keinen Umständen stören.
#
# Beantwortet die drei Fragen, die man während und nach einem Lauf stellt:
# läuft gerade etwas, wie ist der letzte ausgegangen, und darf der nächste.
status_zeigen() {
  local jetzt lauf_pid start dauer letztes_log fortschritt n gesamt
  local rest tempo rest_min log letzte_zeile
  jetzt=$(date +%s)

  echo "Fotoexport – Status vom $(date '+%d.%m.%Y, %H:%M:%S')"
  echo

  # --- Läuft gerade einer? ------------------------------------------------
  lauf_pid=""
  if [ -e "$LOCKDATEI" ]; then
    lauf_pid="$(cat "$LOCKDATEI" 2>/dev/null || true)"
    if [ -z "$lauf_pid" ] || ! kill -0 "$lauf_pid" 2>/dev/null; then
      lauf_pid=""
    fi
  fi

  if [ -n "$lauf_pid" ]; then
    start=$(stat -f %m "$LOCKDATEI")
    dauer=$(( jetzt - start ))
    echo "LÄUFT   seit $(date -r "$start" '+%H:%M:%S') Uhr, $(( dauer / 60 )) min, PID $lauf_pid"

    letztes_log="$(ls -t "$LOGVERZEICHNIS"/export_*.log 2>/dev/null | head -1 || true)"
    fortschritt=""
    [ -n "$letztes_log" ] && fortschritt="$(grep -oE '\([0-9]+/[0-9]+\)' "$letztes_log" 2>/dev/null | tail -1 | tr -d '()' || true)"

    if [ -n "$fortschritt" ]; then
      n="${fortschritt%%/*}"
      gesamt="${fortschritt##*/}"
      echo "        bei Objekt $n von $gesamt ($(( n * 100 / gesamt )) %)"
      # Grobe Schätzung: Der Startaufwand von rund einer halben Minute steckt
      # in der Rate mit drin, die Restzeit fällt dadurch eher zu hoch aus.
      if [ "$dauer" -gt 60 ] && [ "$n" -gt 0 ]; then
        tempo=$(( n / (dauer / 60) ))
        rest=$(( gesamt - n ))
        [ "$tempo" -gt 0 ] && rest_min=$(( rest / tempo )) || rest_min=0
        echo "        $tempo Objekte/min, noch etwa $rest_min min"
      fi
    else
      echo "        noch in der Vorbereitung (Mediathek wird gelesen)"
    fi
  else
    echo "LÄUFT   nichts."
  fi
  echo

  # --- Der letzte vollständige Export --------------------------------------
  log=""
  for kandidat in $(ls -t "$LOGVERZEICHNIS"/export_*.log 2>/dev/null || true); do
    if grep -q "Export fertig" "$kandidat" 2>/dev/null; then log="$kandidat"; break; fi
  done

  if [ -z "$log" ]; then
    echo "LETZTER kein abgeschlossener Export im Protokoll gefunden."
  else
    echo "LETZTER vollständiger Export am $(basename "$log" .log | sed 's/^export_//')"
    letzte_zeile="$(grep 'Processed:' "$log" | tail -1 || true)"
    [ -n "$letzte_zeile" ] && echo "        $letzte_zeile"
    letzte_zeile="$(grep 'Elapsed time:' "$log" | tail -1 || true)"
    [ -n "$letzte_zeile" ] && echo "        $letzte_zeile"
    letzte_zeile="$(grep 'Export fertig' "$log" | tail -1 || true)"
    [ -n "$letzte_zeile" ] && echo "        $letzte_zeile"
    letzte_zeile="$(grep 'Ende, Rückgabewert' "$log" | tail -1 || true)"
    [ -n "$letzte_zeile" ] && echo "        $letzte_zeile"
  fi
  echo

  # --- Darf der nächste geplante Lauf? -------------------------------------
  # Die drei Bedingungen, an denen ein geplanter Lauf still aussteigt. Ohne
  # diese Anzeige sieht man den Grund erst hinterher im Protokoll – und das
  # war zweimal der Fall, bevor es diese Option gab.
  echo "NÄCHSTER geplanter Lauf"

  if [ -f "$STEMPEL" ]; then
    local frei_ab
    frei_ab=$(( $(stat -f %m "$STEMPEL") + MINDESTABSTAND_STUNDEN * 3600 ))
    if [ "$jetzt" -ge "$frei_ab" ]; then
      echo "        Abstand   frei (letzter Lauf $(date -r "$(stat -f %m "$STEMPEL")" '+%d.%m. %H:%M'))"
    else
      echo "        Abstand   gesperrt bis $(date -r "$frei_ab" '+%d.%m. %H:%M') (Mindestabstand ${MINDESTABSTAND_STUNDEN} h)"
    fi
  else
    echo "        Abstand   frei (kein Stempel vorhanden)"
  fi

  if /usr/bin/pmset -g ps | grep -q "AC Power"; then
    echo "        Netzteil  angeschlossen"
  elif [ "$NETZTEIL_NOETIG" = "ja" ]; then
    echo "        Netzteil  FEHLT – der Lauf würde ausgelassen"
  else
    echo "        Netzteil  fehlt, aber NETZTEIL_NOETIG=nein"
  fi

  if /usr/bin/nc -z -G 3 "$SERVER" 445 >/dev/null 2>&1; then
    echo "        Server    $SERVER erreichbar"
  else
    echo "        Server    $SERVER NICHT erreichbar – der Lauf würde ausgelassen"
  fi

  echo "        Platz     $(frei_gb) GB frei (Untergrenze $MINDESTFREI_GB GB)"
  echo

  # --- Der Bestand am Ziel -------------------------------------------------
  # Gezählt wird auf dem Server per SSH, nicht über den SMB-Mount: Das ist um
  # Längen schneller und stört einen laufenden Export nicht. Ohne SSH-Zugang
  # fehlt nur dieser Block, alles andere funktioniert.
  echo "ZIEL"
  if [ -f "$EXPORTDB" ]; then
    echo "        Exportdb  $(/usr/bin/du -h "$EXPORTDB" | cut -f1) (lokal)"
  fi

  local ssh_user zahlen dateien groesse
  ssh_user="${SSH_USER:-${SMB_USER:-}}"
  zahlen=""
  if [ -n "$ssh_user" ] && [ -n "${BESTAND:-}" ]; then
    zahlen="$(ssh -o BatchMode=yes -o ConnectTimeout=5 "${ssh_user}@${SERVER}" \
      "find '$BESTAND' -type f ! -name '*.xmp' ! -path '*/_berichte/*' ! -path '*/_geloescht/*' | wc -l; du -sh '$BESTAND' | cut -f1" 2>/dev/null || true)"
  fi

  if [ -n "$zahlen" ]; then
    dateien="$(echo "$zahlen" | sed -n 1p | tr -d ' ')"
    groesse="$(echo "$zahlen" | sed -n 2p)"
    echo "        Bestand   $dateien Dateien, $groesse auf $SERVER"
  else
    echo "        Bestand   nicht ermittelbar (kein SSH-Zugang zu $SERVER)"
  fi
}

if [ "$STATUS" -eq 1 ]; then
  if [ "$WATCH" -eq 1 ]; then
    # Ctrl-C beendet die Anzeige, nicht den Export – status_zeigen fasst
    # nichts an.
    while true; do clear; status_zeigen; echo; echo "(alle 60 s, Ctrl-C beendet die Anzeige)"; sleep 60; done
  fi
  status_zeigen
  exit 0
fi

# ---------------------------------------------------------------------------
# Aufräumen – läuft bei jedem Ende, auch bei Fehler oder Ctrl-C
# ---------------------------------------------------------------------------
AUFGEHAENGT=0
WAECHTER_PID=""

aufraeumen() {
  local code=$?
  [ -n "$WAECHTER_PID" ] && kill "$WAECHTER_PID" 2>/dev/null
  if [ "$AUFGEHAENGT" -eq 1 ]; then
    melde "Verbindung wird getrennt."
    # Erst normal, dann bestimmt. Ein hängender SMB-Mount blockiert sonst
    # den nächsten Lauf und lässt den Finder einfrieren.
    if ! /sbin/umount "$MOUNTPOINT" 2>/dev/null; then
      sleep 2
      /sbin/umount -f "$MOUNTPOINT" 2>/dev/null \
        || melde "WARNUNG: $MOUNTPOINT liess sich nicht trennen."
    fi
    rmdir "$MOUNTPOINT" 2>/dev/null
  fi
  rm -f "$LOCKDATEI"
  melde "Ende, Rückgabewert $code."
  exit $code
}
trap aufraeumen EXIT INT TERM

# ---------------------------------------------------------------------------
# Nur ein Lauf gleichzeitig
# ---------------------------------------------------------------------------
if [ -e "$LOCKDATEI" ]; then
  ALTPID="$(cat "$LOCKDATEI" 2>/dev/null)"
  if [ -n "$ALTPID" ] && kill -0 "$ALTPID" 2>/dev/null; then
    echo "Es läuft bereits ein Export (PID $ALTPID). Abbruch."
    trap - EXIT; exit 1
  fi
  rm -f "$LOCKDATEI"
fi
echo $$ > "$LOCKDATEI"

# Der Zusatz "(geplant)" macht im Protokoll unterscheidbar, welche Läufe von
# der Automatik kamen. Das Prüfskript sucht danach: Der Rückgabewert eines
# App-Bundles ist nicht verlässlich, das Protokoll dagegen schon.
if [ "$GEPLANT" -eq 1 ]; then
  melde "=== Fotoexport $DATUM (geplant) ==="
else
  melde "=== Fotoexport $DATUM ==="
fi
melde "Konfiguration: $KONFIG"

# ---------------------------------------------------------------------------
# Vorprüfungen
# ---------------------------------------------------------------------------
# Bei geplanten Läufen sind fehlendes Netzteil und fremdes Netz keine Fehler,
# sondern normale Gründe, es sein zu lassen. Ein Fehlercode würde launchd und
# das Prüfskript Alarm schlagen lassen, wo nichts kaputt ist.
if [ "$GEPLANT" -eq 1 ]; then
  # Ein Laptop wird meist im Akkubetrieb aufgeklappt und erst später
  # eingesteckt. Ein einziger Termin pro Tag träfe fast immer den falschen
  # Moment. Deshalb fragt launchd häufig nach, und hier wird entschieden:
  # gelaufen wird, wenn seit dem letzten erfolgreichen Lauf genug Zeit
  # vergangen ist UND die Bedingungen stimmen.
  if [ -f "$STEMPEL" ]; then
    ALTER_STD=$(( ( $(date +%s) - $(stat -f %m "$STEMPEL") ) / 3600 ))
    if [ "$ALTER_STD" -lt "$MINDESTABSTAND_STUNDEN" ]; then
      # Kein Logeintrag: Diese Prüfung läuft oft und würde das Protokoll
      # sonst zumüllen.
      trap - EXIT; rm -f "$LOCKDATEI"; exit 0
    fi
  fi

  # Ein voller Lauf dauert gut eine Stunde und hält Platte, Netz und PhotoKit
  # beschäftigt – im Akkubetrieb ist das selten erwünscht. Wer es doch will,
  # setzt NETZTEIL_NOETIG=nein.
  #
  # Zu bedenken: caffeinate -s wirkt nur am Netzteil. Im Akkubetrieb bleibt
  # -i, das den Leerlauf-Ruhezustand verhindert, solange der Deckel offen
  # ist. Deckel zu heisst Lauf zu Ende.
  if [ "$NETZTEIL_NOETIG" = "ja" ]; then
    if ! /usr/bin/pmset -g ps | grep -q "AC Power"; then
      melde "Kein Netzteil – Lauf verschoben. Nächster Versuch in Kürze."
      exit 0
    fi
    melde "Am Netzteil."
  elif /usr/bin/pmset -g ps | grep -q "AC Power"; then
    melde "Am Netzteil."
  else
    melde "Akkubetrieb – läuft trotzdem (NETZTEIL_NOETIG=nein)."
    melde "Deckel offen lassen, sonst bricht der Lauf ab."
  fi
fi

if ! /usr/bin/nc -z -G 5 "$SERVER" 445 >/dev/null 2>&1; then
  if [ "$GEPLANT" -eq 1 ]; then
    melde "$SERVER nicht erreichbar – vermutlich ausser Haus."
    melde "Lauf wird ausgelassen."
    exit 0
  fi
  melde "FEHLER: $SERVER antwortet nicht auf Port 445."
  exit 1
fi
melde "$SERVER erreichbar."

if [ ! -x "$OSXPHOTOS" ]; then
  melde "FEHLER: osxphotos nicht gefunden unter $OSXPHOTOS."
  exit 1
fi

# ---------------------------------------------------------------------------
# Verbinden
# ---------------------------------------------------------------------------
if /sbin/mount | grep -q " $MOUNTPOINT "; then
  melde "Alter Mount gefunden, wird getrennt."
  /sbin/umount -f "$MOUNTPOINT" 2>/dev/null
fi

mkdir -p "$MOUNTPOINT"

# Das Passwort steht nicht im Skript, sondern im Schlüsselbund.
#
# mount_smbfs fragt den Schlüsselbund nicht von sich aus – das erledigt im
# Finder eine Schicht darüber (NetAuth). Und `-N` heisst nicht "nimm das
# gespeicherte Passwort", sondern "frag nicht nach": mount_smbfs sendet dann
# ein leeres Passwort. Deshalb wird es hier ausdrücklich geholt.
PASSWORT="$(security find-internet-password -s "$SERVER" -a "$SMB_USER" -w 2>/dev/null)"
if [ -z "$PASSWORT" ]; then
  PASSWORT="$(security find-generic-password -s "$KEYCHAIN_DIENST" -a "$SMB_USER" -w 2>/dev/null)"
fi
if [ -z "$PASSWORT" ]; then
  melde "FEHLER: kein Passwort im Schlüsselbund gefunden."
  melde "Einmal im Finder mit ⌘K auf smb://$SERVER/$SHARE verbinden und dabei"
  melde "'Passwort im Schlüsselbund sichern' ankreuzen. Oder von Hand anlegen:"
  melde "  security add-generic-password -a $SMB_USER -s $KEYCHAIN_DIENST -T /usr/bin/security -w"
  rmdir "$MOUNTPOINT" 2>/dev/null
  exit 1
fi

# Sonderzeichen im Passwort für die URL kodieren, sonst zerlegt ein @ oder /
# die Mount-URL
PASSWORT_URL="$(printf '%s' "$PASSWORT" | LC_ALL=C awk '
  BEGIN { for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i }
  {
    for (i = 1; i <= length($0); i++) {
      c = substr($0, i, 1)
      if (c ~ /[A-Za-z0-9._~-]/) printf "%s", c
      else printf "%%%02X", ord[c]
    }
  }')"

if ! /sbin/mount_smbfs "//$SMB_USER:$PASSWORT_URL@$SERVER/$SHARE" "$MOUNTPOINT" 2>>"$LOG"; then
  melde "FEHLER: Verbindung zu //$SERVER/$SHARE fehlgeschlagen."
  unset PASSWORT PASSWORT_URL
  rmdir "$MOUNTPOINT" 2>/dev/null
  exit 1
fi
unset PASSWORT PASSWORT_URL
AUFGEHAENGT=1
melde "Verbunden: $MOUNTPOINT"

mkdir -p "$MOUNTPOINT/_berichte" 2>>"$LOG"

# Der Schreibtest liegt in _berichte und trägt einen gewöhnlichen Namen:
# Punktdateien werden von manchen Samba-Konfigurationen ausgeblendet oder
# weggeworfen, und dann sucht man den Fehler an der falschen Stelle.
TESTDATEI="$MOUNTPOINT/_berichte/schreibtest_$$"
if ! touch "$TESTDATEI" 2>>"$LOG"; then
  melde "FEHLER: kein Schreibzugriff auf die Freigabe."
  melde "Diagnose:"
  /sbin/mount | grep " $MOUNTPOINT " | sed 's/^/    /' | tee -a "$LOG"
  ls -ld "$MOUNTPOINT" "$MOUNTPOINT/_berichte" 2>&1 | sed 's/^/    /' | tee -a "$LOG"
  melde "Wer bin ich: $(id -un) ($(id -u))"
  exit 1
fi
rm -f "$TESTDATEI"

# ---------------------------------------------------------------------------
# Platzwächter
# ---------------------------------------------------------------------------
# --download-missing holt fehlende Originale über PhotoKit. Apple legt sie
# dabei zuerst in die lokale Mediathek; erst danach kopiert osxphotos sie
# weiter. Die Mediathek wächst also während des Laufs.
FREI_START="$(frei_gb)"
melde "Freier Platz: $FREI_START GB (Untergrenze $MINDESTFREI_GB GB)."

if [ "$FREI_START" -lt "$MINDESTFREI_GB" ]; then
  melde "FEHLER: schon vor dem Start unter der Untergrenze. Abbruch."
  exit 1
fi

if [ "$DRY_RUN" -eq 0 ]; then
  (
    while sleep 60; do
      FREI="$(frei_gb)"
      if [ "$FREI" -lt "$MINDESTFREI_GB" ]; then
        melde "STOPP: nur noch $FREI GB frei. Export wird beendet."
        melde "Speicher optimieren lassen, dann denselben Aufruf wiederholen."
        pkill -TERM -f "osxphotos export"
        break
      fi
    done
  ) &
  WAECHTER_PID=$!
fi

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------
# Probeläufe schreiben unter eigenem Namen.
#
# Sonst überschreibt ein Testlauf am selben Tag den Bericht des letzten
# Vollexports – und damit die Grundlage des Löschabgleichs. Ein Bericht über
# ein einzelnes Album kennt nur einen Bruchteil des Bestands; würde er den
# vollständigen ersetzen, sähe fast alles verwaist aus.
if [ -n "$ALBUM" ] || [ "$DRY_RUN" -eq 1 ]; then
  BERICHT="$MOUNTPOINT/_berichte/probe_$DATUM.csv"
else
  BERICHT="$MOUNTPOINT/_berichte/export_$DATUM.csv"
fi

ARGS=(
  export "$MOUNTPOINT"
  --update
  --download-missing --use-photokit
  --directory "{created.year}/{created.mm}"
  --filename "{created.strftime,%Y%m%d_%H%M%S}_{original_name}"
  --exportdb "$EXPORTDB"
  --sidecar XMP
  --edited-suffix "_bearbeitet"
  --touch-file
  --retry 3
  --report "$BERICHT"
  --verbose
)

[ -n "$ALBUM" ]      && ARGS+=(--album "$ALBUM")
[ "$DRY_RUN" -eq 1 ] && ARGS+=(--dry-run)

[ -n "$ALBUM" ]      && melde "Testlauf über Album: $ALBUM"
[ "$DRY_RUN" -eq 1 ] && melde "Trockenlauf – es wird nichts geschrieben."

# Die Fertigmarkierung entfernen, solange dieser Lauf läuft: osxphotos
# schreibt den Bericht fortlaufend, nicht am Ende – ein Abgleich mitten im
# Lauf sähe den halben Bestand als verwaist an.
#
# Nur bei einem Volllauf. Ein Probelauf darf die Markierung eines früheren
# vollständigen Laufs am selben Tag nicht antasten.
if [ -z "$ALBUM" ] && [ "$DRY_RUN" -eq 0 ]; then
  rm -f "$BERICHT.fertig"
fi

melde "Export startet. Der Mac darf nicht schlafen, Deckel offen lassen."

# caffeinate -i verhindert den Leerlauf-Schlaf, -s zusätzlich bei Netzbetrieb.
# Gegen einen geschlossenen Deckel hilft es nicht.
/usr/bin/caffeinate -i -s "$OSXPHOTOS" "${ARGS[@]}" 2>&1 | tee -a "$LOG"
CODE=${PIPESTATUS[0]}

[ -n "$WAECHTER_PID" ] && kill "$WAECHTER_PID" 2>/dev/null
WAECHTER_PID=""

melde "Freier Platz jetzt: $(frei_gb) GB (vorher $FREI_START GB)."

if [ "$CODE" -ne 0 ]; then
  melde "Export mit Fehlercode $CODE beendet. Derselbe Aufruf setzt fort."
elif [ "$DRY_RUN" -eq 1 ]; then
  melde "Trockenlauf beendet – es wurde nichts geschrieben."
elif [ -n "$ALBUM" ]; then
  melde "Albumlauf beendet. Bericht: $(basename "$BERICHT")"
  melde "Keine Fertigmarkierung – der Bericht deckt nur einen Teil des"
  melde "Bestands ab und taugt nicht für den Löschabgleich."
else
  ANZAHL=$(find "$MOUNTPOINT" -type f ! -name "*.xmp" ! -path "*/_berichte/*" \
           ! -path "*/_geloescht/*" 2>/dev/null | wc -l | tr -d ' ')
  melde "Export fertig. $ANZAHL Dateien am Ziel (ohne XMP)."

  # Erst jetzt ist der Bericht vollständig und darf als Grundlage für den
  # Löschabgleich dienen.
  date -u +"%Y-%m-%dT%H:%M:%SZ" > "$BERICHT.fertig"
  melde "Bericht abgeschlossen: $(basename "$BERICHT")"

  # Merker für den Mindestabstand geplanter Läufe
  touch "$STEMPEL"

  # Kopie der Exportdatenbank aufs Ziel. Sie ist regenerierbar, aber ihr
  # Neuaufbau kostet einen kompletten Vergleichslauf über alle Objekte.
  cp "$EXPORTDB" "$MOUNTPOINT/_berichte/osxphotos_export.db" 2>/dev/null \
    && melde "Exportdatenbank gesichert."
fi

exit $CODE
