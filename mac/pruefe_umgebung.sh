#!/bin/bash
#
# pruefe_umgebung.sh – prüft, was für Betrieb und Installation vorhanden ist.
#
# Dieses Skript ändert nichts. Es legt keine Ordner an, installiert nichts
# und schreibt keine Konfiguration. Es liest, vergleicht und sagt, was fehlt.
#
# Der Server wird per SSH mitgeprüft, sofern eine Verbindung ohne
# Passwortabfrage besteht. Ohne SSH bleibt der Serverteil einfach leer.
#
#   ./pruefe_umgebung.sh              alle Prüfungen
#   ./pruefe_umgebung.sh --mediathek  zusätzlich die Fotomediathek abfragen
#                                     (kann einen Berechtigungsdialog auslösen)
#   ./pruefe_umgebung.sh --smb        Freigabe kurz einhängen, Schreibzugriff
#                                     prüfen, wieder aushängen. Einzige
#                                     Prüfung, die vorübergehend etwas tut –
#                                     deshalb ausdrücklich anzufordern.
#
# Rückgabewert 0, wenn nichts fehlt, sonst 1.

set -u

TIEF=0
SMBTEST=0
for A in "$@"; do
  case "$A" in
    --mediathek) TIEF=1 ;;
    --smb)       SMBTEST=1 ;;
  esac
done

if [ -t 1 ]; then
  GRUEN=$'\033[32m'; ROT=$'\033[31m'; GELB=$'\033[33m'
  FETT=$'\033[1m';   AUS=$'\033[0m'
else
  GRUEN=""; ROT=""; GELB=""; FETT=""; AUS=""
fi

FEHLT=0
WARNUNGEN=0
NAECHSTER=""

ok()      { printf "  %s✓%s %s\n" "$GRUEN" "$AUS" "$1"; }
fehlt()   { printf "  %s✗%s %s\n" "$ROT" "$AUS" "$1"; [ -n "${2:-}" ] && printf "      → %s\n" "$2"; FEHLT=$((FEHLT+1)); }
warnung() { printf "  %s!%s %s\n" "$GELB" "$AUS" "$1"; [ -n "${2:-}" ] && printf "      → %s\n" "$2"; WARNUNGEN=$((WARNUNGEN+1)); }
info()    { printf "    %s\n" "$1"; }
titel()   { printf "\n%s%s%s\n" "$FETT" "$1" "$AUS"; }

merke_schritt() { [ -z "$NAECHSTER" ] && NAECHSTER="$1"; }

printf "\n%sPrüfung der Umgebung%s\n" "$FETT" "$AUS"
printf "Dieses Skript ändert nichts.\n"

# Ein laufender Export erklärt mehrere Beobachtungen, die sonst wie Fehler
# aussehen: belegter Mountpoint, unfertiger Bericht, Protokoll ohne Abschluss.
LAEUFT=0
if pgrep -f "osxphotos export" > /dev/null 2>&1; then
  LAEUFT=1
  printf "\n%sHinweis: Es läuft gerade ein Export.%s\n" "$GELB" "$AUS"
  printf "Einige Punkte sind deshalb vorübergehend auffällig.\n"
fi

# ---------------------------------------------------------------------------
titel "Konfiguration"
# ---------------------------------------------------------------------------
HIER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KONFIG=""
for K in "$HIER/config" "$HIER/../config" "$HOME/.config/fotobackup/config"; do
  if [ -f "$K" ]; then KONFIG="$K"; break; fi
done

if [ -z "$KONFIG" ]; then
  fehlt "keine Konfigurationsdatei gefunden" "cp config.example config"
  merke_schritt "Konfiguration anlegen – installation.md, Schritt 5"
  printf "\nOhne Konfiguration ist keine weitere Prüfung möglich.\n\n"
  exit 1
fi
ok "Konfiguration: $KONFIG"
# shellcheck source=/dev/null
. "$KONFIG"

for V in SERVER SHARE SMB_USER BESTAND MOUNTPOINT; do
  if [ -z "${!V:-}" ]; then
    fehlt "$V fehlt in der Konfiguration" "Wert in $KONFIG eintragen"
  fi
done
[ "$FEHLT" -eq 0 ] && ok "alle Pflichtwerte gesetzt"

OSXPHOTOS="${OSXPHOTOS:-$HOME/.local/bin/osxphotos}"
EXPORTDB="${EXPORTDB:-$HOME/Library/Application Support/fotoexport/osxphotos_export.db}"
MINDESTFREI_GB="${MINDESTFREI_GB:-8}"
SSH_USER="${SSH_USER:-$SMB_USER}"

# ---------------------------------------------------------------------------
titel "Mac"
# ---------------------------------------------------------------------------
if [ -x "$OSXPHOTOS" ]; then
  ok "osxphotos $("$OSXPHOTOS" --version 2>/dev/null | head -1 | awk '{print $NF}')"
else
  fehlt "osxphotos nicht gefunden unter $OSXPHOTOS" "pipx install osxphotos"
  merke_schritt "osxphotos installieren – installation.md, Schritt 4"
fi

command -v sqlite3 > /dev/null \
  && ok "sqlite3 vorhanden" \
  || warnung "sqlite3 fehlt" "fotostatus.sh zeigt dann keinen Fortschritt in Prozent"

# Der grosse Zuwachs entsteht beim Erstlauf, wenn alle fehlenden Originale
# aus iCloud geholt werden. Existiert bereits eine Exportdatenbank, ist dieser
# Berg überwunden und knapper Platz kein Warnzeichen mehr.
ERSTLAUF_OFFEN=1
[ -f "$EXPORTDB" ] && ERSTLAUF_OFFEN=0

FREI="$(/bin/df -g / | awk 'NR==2 {print $4}')"
if [ "$FREI" -lt "$MINDESTFREI_GB" ]; then
  fehlt "nur $FREI GB frei, Untergrenze ist $MINDESTFREI_GB GB" \
        "Speicher freigeben, der Export würde sofort abbrechen"
elif [ "$FREI" -lt 60 ] && [ "$ERSTLAUF_OFFEN" -eq 1 ]; then
  warnung "$FREI GB frei" \
          "Beim Erstlauf wächst die Mediathek stark – siehe installation.md, Schritt 2"
else
  ok "$FREI GB frei auf der Systemplatte"
  [ "$FREI" -lt 60 ] && info "knapp, aber der Erstlauf ist durch – Folgeläufe brauchen kaum Platz"
fi

if [ -f "$EXPORTDB" ]; then
  ok "Exportdatenbank vorhanden ($(du -h "$EXPORTDB" | cut -f1))"
  if command -v sqlite3 > /dev/null; then
    OBJEKTE="$(sqlite3 "$EXPORTDB" "SELECT count(*) FROM photoinfo;" 2>/dev/null)"
    [ -n "$OBJEKTE" ] && info "$OBJEKTE Objekte beim letzten Lauf"
  fi
else
  info "noch keine Exportdatenbank – der erste Lauf legt sie an"
fi

if [ "$TIEF" -eq 1 ] && [ -x "$OSXPHOTOS" ]; then
  if "$OSXPHOTOS" info > /tmp/.fb_info 2>&1; then
    ok "Zugriff auf die Fotomediathek"
  else
    fehlt "kein Zugriff auf die Fotomediathek" \
          "Systemeinstellungen → Datenschutz & Sicherheit → Fotos"
  fi
  rm -f /tmp/.fb_info
fi

# ---------------------------------------------------------------------------
titel "Verbindung"
# ---------------------------------------------------------------------------
if /usr/bin/nc -z -G 5 "$SERVER" 445 > /dev/null 2>&1; then
  ok "$SERVER antwortet auf Port 445"
else
  fehlt "$SERVER antwortet nicht auf Port 445" \
        "Läuft der Server? Ist smbd aktiv? Stimmt die Adresse?"
  merke_schritt "Samba einrichten – installation.md, Schritt 3"
fi

# Ohne -w wird nur nach dem Eintrag gesucht, nicht nach dem Passwort.
# Das löst keinen Schlüsselbund-Dialog aus.
if security find-internet-password -s "$SERVER" -a "$SMB_USER" > /dev/null 2>&1; then
  ok "Schlüsselbund-Eintrag für $SMB_USER@$SERVER"
elif security find-generic-password -s "${KEYCHAIN_DIENST:-fotobackup}" -a "$SMB_USER" > /dev/null 2>&1; then
  ok "Schlüsselbund-Eintrag (eigener Dienst ${KEYCHAIN_DIENST:-fotobackup})"
else
  fehlt "kein Schlüsselbund-Eintrag gefunden" \
        "Im Finder ⌘K auf smb://$SERVER/$SHARE, Passwort sichern ankreuzen"
  merke_schritt "Schlüsselbund-Eintrag anlegen – installation.md, Schritt 6"
fi

if /sbin/mount | grep -q " $MOUNTPOINT "; then
  if [ "$LAEUFT" -eq 1 ]; then
    ok "Freigabe eingehängt (der laufende Export benutzt sie)"
  else
    warnung "unter $MOUNTPOINT ist bereits etwas eingehängt" \
            "Der Export trennt das zu Beginn – meist harmlos"
  fi
else
  ok "Mountpoint frei"
fi

# Der einzige Test, der vorübergehend etwas tut: einhängen, schreiben,
# aushängen. Auf einem eigenen Pfad, damit ein laufender Export unberührt
# bleibt. Nur mit --smb, und mit garantiertem Aufräumen.
if [ "$SMBTEST" -eq 1 ] && [ "$LAEUFT" -eq 0 ]; then
  TESTMOUNT="$HOME/mnt/.pruefung.$$"
  aufraeumen_smb() { /sbin/umount "$TESTMOUNT" 2>/dev/null || /sbin/umount -f "$TESTMOUNT" 2>/dev/null; rmdir "$TESTMOUNT" 2>/dev/null; }
  trap aufraeumen_smb EXIT INT TERM

  PW="$(security find-internet-password -s "$SERVER" -a "$SMB_USER" -w 2>/dev/null)"
  [ -z "$PW" ] && PW="$(security find-generic-password -s "${KEYCHAIN_DIENST:-fotobackup}" -a "$SMB_USER" -w 2>/dev/null)"

  if [ -z "$PW" ]; then
    warnung "SMB-Test übersprungen – kein Passwort im Schlüsselbund"
  else
    PW_URL="$(printf '%s' "$PW" | LC_ALL=C awk '
      BEGIN { for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i }
      { for (i = 1; i <= length($0); i++) { c = substr($0, i, 1)
          if (c ~ /[A-Za-z0-9._~-]/) printf "%s", c; else printf "%%%02X", ord[c] } }')"
    mkdir -p "$TESTMOUNT"
    if /sbin/mount_smbfs "//$SMB_USER:$PW_URL@$SERVER/$SHARE" "$TESTMOUNT" 2>/dev/null; then
      ok "Freigabe lässt sich einhängen"
      T="$TESTMOUNT/_berichte/schreibtest_$$"
      if touch "$T" 2>/dev/null; then
        ok "Schreibzugriff vorhanden"
        rm -f "$T"
      else
        fehlt "kein Schreibzugriff auf die Freigabe" \
              "Samba: read only, valid users, force user – und Rechte am Zielordner"
      fi
    else
      fehlt "Freigabe lässt sich nicht einhängen" \
            "Passwort im Schlüsselbund und Samba-Konfiguration prüfen"
    fi
    unset PW PW_URL
  fi
  aufraeumen_smb
  trap - EXIT INT TERM
elif [ "$SMBTEST" -eq 1 ]; then
  info "SMB-Test übersprungen – es läuft gerade ein Export"
fi

# ---------------------------------------------------------------------------
titel "Server"
# ---------------------------------------------------------------------------
if ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_USER@$SERVER" true 2>/dev/null; then
  ok "SSH-Zugang ohne Passwort"

  SERVERDATEN="$(ssh -o BatchMode=yes "$SSH_USER@$SERVER" "
    echo \"BESTAND=\$([ -d '$BESTAND' ] && echo ja || echo nein)\"
    echo \"SCHREIBBAR=\$([ -w '$BESTAND' ] && echo ja || echo nein)\"
    echo \"FREI=\$(df -BG --output=avail '$BESTAND' 2>/dev/null | tail -1 | tr -dc 0-9)\"
    echo \"DATEIEN=\$(find '$BESTAND' -type f ! -name '*.xmp' ! -path '*/_berichte/*' ! -path '*/_geloescht/*' 2>/dev/null | wc -l)\"
    echo \"B3SUM=\$(command -v b3sum > /dev/null && echo ja || echo nein)\"
    echo \"MOSQ=\$(command -v mosquitto_pub > /dev/null && echo ja || echo nein)\"
    echo \"SMBD=\$(systemctl is-active smbd 2>/dev/null || echo unbekannt)\"
    echo \"SKRIPTE=\$([ -f ~/fotobackup/pruefe_bestand.py ] && echo ja || echo nein)\"
    echo \"SRVKONFIG=\$([ -f ~/fotobackup/config ] && echo ja || echo nein)\"
    echo \"LISTE=\$([ -f ~/fotobackup/pruefsummen/b3.liste ] && wc -l < ~/fotobackup/pruefsummen/b3.liste || echo 0)\"
    echo \"CRON=\$(crontab -l 2>/dev/null | grep -c pruefe_bestand)\"
    echo \"BERICHTE=\$(ls '$BESTAND'/_berichte/export_*.csv 2>/dev/null | wc -l)\"
    echo \"FERTIG=\$(ls '$BESTAND'/_berichte/*.fertig 2>/dev/null | wc -l)\"
    echo \"QUARANTAENE=\$(find '$BESTAND/_geloescht' -type f 2>/dev/null | wc -l)\"
    echo \"LETZTERVOLL=\$(ls -t '$BESTAND'/_berichte/*.fertig 2>/dev/null | head -1 | xargs -r stat -c %Y 2>/dev/null)\"
  " 2>/dev/null)"

  hole() { echo "$SERVERDATEN" | grep "^$1=" | cut -d= -f2- | tr -d ' '; }

  [ "$(hole BESTAND)" = "ja" ] \
    && ok "Bestandsordner $BESTAND vorhanden" \
    || fehlt "Bestandsordner $BESTAND fehlt" "mkdir -p $BESTAND auf dem Server"

  [ "$(hole SCHREIBBAR)" = "ja" ] \
    && ok "beschreibbar" \
    || fehlt "keine Schreibrechte auf $BESTAND" "Eigentümer und Rechte prüfen"

  SFREI="$(hole FREI)"
  [ -n "$SFREI" ] && info "$SFREI GB frei auf dem Server"

  DATEIEN="$(hole DATEIEN)"
  [ "${DATEIEN:-0}" -gt 0 ] && ok "$DATEIEN Bilddateien im Bestand"

  [ "$(hole SMBD)" = "active" ] \
    && ok "smbd läuft" \
    || warnung "smbd ist $(hole SMBD)" "systemctl status smbd auf dem Server"

  [ "$(hole B3SUM)" = "ja" ] \
    && ok "b3sum vorhanden" \
    || { fehlt "b3sum fehlt auf dem Server" "sudo apt install b3sum"
         merke_schritt "Bestandsprüfung einrichten – installation.md, Schritt 11"; }

  if [ -n "${MQTT_HOST:-}" ]; then
    [ "$(hole MOSQ)" = "ja" ] \
      && ok "mosquitto_pub vorhanden" \
      || fehlt "mosquitto_pub fehlt" "sudo apt install mosquitto-clients"
  else
    info "kein MQTT_HOST konfiguriert – Meldungen sind abgeschaltet"
  fi

  [ "$(hole SKRIPTE)" = "ja" ] \
    && ok "Skripte unter ~/fotobackup" \
    || { fehlt "Skripte fehlen auf dem Server" "scp pi/*.py pi/*.sh config BENUTZER@$SERVER:~/fotobackup/"
         merke_schritt "Bestandsprüfung einrichten – installation.md, Schritt 11"; }

  [ "$(hole SRVKONFIG)" = "ja" ] \
    && ok "Konfiguration auf dem Server" \
    || fehlt "keine config auf dem Server" "scp config BENUTZER@$SERVER:~/fotobackup/"

  LISTE="$(hole LISTE)"
  if [ "${LISTE:-0}" -gt 0 ]; then
    ok "Prüfsummenliste mit $LISTE Einträgen"
  else
    warnung "noch keine Prüfsummenliste" "~/fotobackup/pruefe_bestand.py einmal starten"
  fi

  [ "$(hole CRON)" -gt 0 ] 2>/dev/null \
    && ok "cron-Eintrag für die Bestandsprüfung" \
    || warnung "kein cron-Eintrag" "installation.md, Schritt 11"

  BERICHTE="$(hole BERICHTE)"; FERTIGE="$(hole FERTIG)"
  if [ "${BERICHTE:-0}" -eq 0 ]; then
    warnung "kein Exportbericht auf dem Server" "Noch kein vollständiger Export gelaufen"
    merke_schritt "Erstlauf – installation.md, Schritt 9"
  elif [ "${FERTIGE:-0}" -eq 0 ] && [ "$LAEUFT" -eq 1 ]; then
    info "$BERICHTE Bericht(e), Markierung folgt am Ende des laufenden Exports"
  elif [ "${FERTIGE:-0}" -eq 0 ]; then
    warnung "$BERICHTE Bericht(e), aber keiner ist als vollständig markiert" \
            "Der Löschabgleich verweigert die Arbeit, bis ein Volllauf durch ist"
  else
    ok "$BERICHTE Bericht(e), davon $FERTIGE vollständig"
  fi

  Q="$(hole QUARANTAENE)"
  [ "${Q:-0}" -gt 0 ] && info "$Q Datei(en) in der Quarantäne"

  # Der eigentliche Totmannschalter der Mac-Seite. Ein geplanter Lauf, der
  # wegen Akkubetrieb oder fremdem Netz ausgelassen wurde, meldet sich nicht –
  # das ist Absicht. Bleibt es aber dauerhaft dabei, veraltet das Backup
  # unbemerkt. Verglichen wird das Alter des jüngsten vollständigen Berichts.
  LETZTERVOLL="$(hole LETZTERVOLL)"
  if [ -n "$LETZTERVOLL" ] && [ "$LETZTERVOLL" -gt 0 ] 2>/dev/null; then
    TAGE=$(( ( $(date +%s) - LETZTERVOLL ) / 86400 ))
    if [ "$TAGE" -gt 10 ]; then
      fehlt "letzter vollständiger Export vor $TAGE Tagen" \
            "Läuft die Automatik? ./mac/fotoexport.sh von Hand starten"
      merke_schritt "Export nachholen – betrieb.md"
    elif [ "$TAGE" -gt 3 ]; then
      warnung "letzter vollständiger Export vor $TAGE Tagen"
    else
      ok "letzter vollständiger Export vor $TAGE Tag(en)"
    fi
  fi

else
  warnung "kein SSH-Zugang zu $SSH_USER@$SERVER" \
          "Serverseite wird nicht geprüft. Für fotostatus.sh wird SSH gebraucht."
fi

# ---------------------------------------------------------------------------
titel "Automatik"
# ---------------------------------------------------------------------------
LABEL="local.fotobackup.export"
if launchctl print "gui/$(id -u)/$LABEL" > /dev/null 2>&1; then
  ok "LaunchAgent $LABEL ist geladen"

  # Der Kern der Fehlersuche: Was ist beim letzten *geplanten* Lauf passiert?
  #
  # Gelesen wird das Protokoll, nicht der Rückgabewert von launchd. Der taugt
  # hier nicht: Läuft der Export über eine App-Hülle, schluckt diese Fehler
  # absichtlich – sonst bliebe ein Hintergrundlauf an einem Dialog hängen.
  # Das Protokoll dagegen hält fest, was wirklich passiert ist.
  GEPLANT_LOG=""
  GEPLANT_BLOCK=""
  for L in $(ls -t "$HOME/Library/Logs/fotoexport/"export_*.log 2>/dev/null | head -5); do
    ZEILE="$(grep -n "(geplant)" "$L" 2>/dev/null | tail -1 | cut -d: -f1)"
    if [ -n "$ZEILE" ]; then
      GEPLANT_LOG="$L"
      GEPLANT_BLOCK="$(tail -n +"$ZEILE" "$L")"
      break
    fi
  done

  if [ -z "$GEPLANT_BLOCK" ]; then
    info "noch kein geplanter Lauf protokolliert"
    info "ausprobieren: launchctl kickstart -k gui/\$(id -u)/$LABEL"
  else
    CODE="$(echo "$GEPLANT_BLOCK" | grep -oE "Rückgabewert [0-9]+" | tail -1 | awk '{print $2}')"
    WANN="$(echo "$GEPLANT_BLOCK" | head -1 | cut -c1-8)"

    if [ -z "$CODE" ]; then
      warnung "letzter geplanter Lauf ($WANN) ohne Abschluss im Protokoll" \
              "Läuft er noch, oder wurde er hart abgebrochen?"
    elif [ "$CODE" = "0" ]; then
      # Ausgelassene Läufe (Akku, fremdes Netz) sind ebenfalls Rückgabewert 0
      if echo "$GEPLANT_BLOCK" | grep -q "verschoben\|ausgelassen"; then
        ok "letzter geplanter Lauf ($WANN) verschoben – $(echo "$GEPLANT_BLOCK" | grep -oE "Kein Netzteil|nicht erreichbar" | head -1)"
      else
        ok "letzter geplanter Lauf ($WANN) ohne Fehler"
      fi
    else
      fehlt "letzter geplanter Lauf ($WANN) endete mit Rückgabewert $CODE"

      GRUND="$(echo "$GEPLANT_BLOCK" \
               | grep -E "FEHLER|Error|not permitted|denied|refused|No such|authorization" \
               | tail -3 | sed 's/^[0-9:]* *//')"
      [ -n "$GRUND" ] && echo "$GRUND" | sed 's/^/      → /'

      # Bekannte Fehlerbilder benennen, statt den Text nur weiterzureichen
      if echo "$GEPLANT_BLOCK" | grep -q "not permitted"; then
        info ""
        info "Das ist kein Rechteproblem auf dem Server, sondern macOS-Datenschutz."
        info "Ein Hintergrundprozess braucht eine eigene Erlaubnis für Netzwerk-"
        info "volumes, und bekommt dafür keinen Dialog – er scheitert still."
        info "Typisch nach macOS-Aktualisierungen: die Berechtigung ist erloschen."
        info ""
        info "Systemeinstellungen → Datenschutz & Sicherheit → Festplattenvollzugriff"
        info "Dort den Eintrag für dieses Vorhaben prüfen und wieder aktivieren."
        info "Fehlt er ganz: ./mac/baue_bundle.sh erzeugt die App-Hülle neu."
      elif echo "$GEPLANT_BLOCK" | grep -q "authorization to access Photos"; then
        info ""
        info "Die Fotos-Berechtigung fehlt dem aufrufenden Programm."
        info "Systemeinstellungen → Datenschutz & Sicherheit → Fotos"
      fi
      merke_schritt "Ursache oben beheben, dann ./mac/fotoexport.sh von Hand starten"
      SCHON_GEMELDET=1
    fi
  fi
elif [ -f "$HOME/Library/LaunchAgents/$LABEL.plist" ]; then
  warnung "LaunchAgent liegt vor, ist aber nicht geladen" \
          "launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/$LABEL.plist"
else
  info "kein LaunchAgent eingerichtet – der Export läuft von Hand (betrieb.md)"
fi

LETZTES_LOG="$(ls -t "$HOME/Library/Logs/fotoexport/"export_*.log 2>/dev/null | head -1)"
if [ -n "$LETZTES_LOG" ]; then
  info "letztes Protokoll: $(basename "$LETZTES_LOG")"
  if [ "$LAEUFT" -eq 1 ]; then
    ok "Export läuft gerade – $(tail -1 "$LETZTES_LOG" | cut -c1-60)"
  elif [ "${SCHON_GEMELDET:-0}" -eq 1 ]; then
    :   # Der Fehler steht bereits oben, mit Ursache
  elif tail -3 "$LETZTES_LOG" | grep -q "Rückgabewert 0"; then
    ok "letzter Lauf ohne Fehler beendet"
  else
    warnung "letzter Lauf endete nicht mit Rückgabewert 0" "tail -20 $LETZTES_LOG"
  fi
fi

# ---------------------------------------------------------------------------
titel "Ergebnis"
# ---------------------------------------------------------------------------
if [ "$FEHLT" -eq 0 ] && [ "$WARNUNGEN" -eq 0 ]; then
  printf "  %sAlles vorhanden.%s\n\n" "$GRUEN" "$AUS"
  exit 0
fi

[ "$FEHLT" -gt 0 ]     && printf "  %s%d Punkt(e) fehlen%s\n" "$ROT" "$FEHLT" "$AUS"
[ "$WARNUNGEN" -gt 0 ] && printf "  %s%d Hinweis(e)%s\n" "$GELB" "$WARNUNGEN" "$AUS"

if [ -n "$NAECHSTER" ]; then
  printf "\n  Nächster Schritt: %s\n" "$NAECHSTER"
fi
printf "\n"

[ "$FEHLT" -gt 0 ] && exit 1
exit 0
