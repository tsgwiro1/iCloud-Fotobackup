#!/usr/bin/env python3
"""
waechter.py – überwacht, ob die beiden regelmässigen Aufgaben noch laufen.

Beantwortet genau eine Frage, für zwei Bereiche: **Kommt noch etwas an?**

  Export vom Mac      Alter des jüngsten Berichts mit Fertigmarkierung
  Bestandsprüfung     Alter der Prüfsummenliste

Beides wird am Ergebnis gemessen, nicht an der Absicht: Eine Aufgabe, die
gelaufen zu sein behauptet, aber nichts hinterlassen hat, gilt als nicht
gelaufen.

Warum auf dem Zielrechner: Ein Melder, der am überwachten System hängt, taugt
nichts – fällt der Mac aus, meldet er auch nicht mehr, dass er ausgefallen ist.
Hier liegen beide Ergebnisse ohnehin, und das Ausbleiben fällt zwangsläufig auf.

Was dieses Skript NICHT kann: sagen, warum nichts kommt. Dafür gibt es
pruefe_umgebung.sh auf dem Mac, das launchd und Protokolle auswertet.

Läuft täglich per cron.

Aufruf:
    ./waechter.py           prüfen und melden
    ./waechter.py --still   nur anzeigen, ohne MQTT
"""

import json
import subprocess
import sys
from datetime import datetime
from pathlib import Path

import konfig

KONFIG, KONFIG_PFAD = konfig.laden()

BESTAND = Path(konfig.pflicht(KONFIG, "BESTAND"))
BERICHTE = BESTAND / "_berichte"
BASIS = Path(__file__).resolve().parent
LISTE = BASIS / "pruefsummen" / "b3.liste"

EXPORT_WARNUNG = int(KONFIG.get("EXPORT_WARNUNG_TAGE", "30"))
EXPORT_FEHLER = int(KONFIG.get("EXPORT_FEHLER_TAGE", "90"))
PRUEFUNG_UEBERFAELLIG = int(KONFIG.get("PRUEFUNG_UEBERFAELLIG_TAGE", "35"))

TOPIC = f"{KONFIG.get('MQTT_PRAEFIX', 'fotoexport')}/waechter/state"

still = "--still" in sys.argv


def alter_in_tagen(pfad):
    """Tage seit der letzten Änderung, oder None."""
    try:
        zeit = datetime.fromtimestamp(pfad.stat().st_mtime).astimezone()
    except OSError:
        return None, None
    return (datetime.now().astimezone() - zeit).days, zeit


def export_zustand():
    """Jüngster Bericht mit Fertigmarkierung.

    Ohne Markierung zählt ein Bericht nicht: Er stammt dann von einem
    abgebrochenen Lauf oder von einem Testlauf über ein einzelnes Album.
    """
    neuester = None
    for markierung in BERICHTE.glob("export_*.csv.fertig"):
        bericht = markierung.with_suffix("")
        if not bericht.exists():
            continue
        zeit = markierung.stat().st_mtime
        if neuester is None or zeit > neuester[1]:
            neuester = (bericht, zeit)

    if neuester is None:
        return {"status": "unbekannt", "alter_tage": -1, "letzter": None,
                "bericht": None, "dateien": 0}

    bericht, zeit = neuester
    letzter = datetime.fromtimestamp(zeit).astimezone()
    alter = (datetime.now().astimezone() - letzter).days

    if alter >= EXPORT_FEHLER:
        status = "versaeumt"
    elif alter >= EXPORT_WARNUNG:
        status = "ueberfaellig"
    else:
        status = "ok"

    try:
        with bericht.open() as f:
            dateien = max(sum(1 for _ in f) - 1, 0)
    except OSError:
        dateien = 0

    return {"status": status, "alter_tage": alter,
            "letzter": letzter.isoformat(timespec="seconds"),
            "bericht": bericht.name, "dateien": dateien}


def pruefung_zustand():
    """Alter der Prüfsummenliste – sie wird bei jedem Lauf neu geschrieben."""
    alter, zeit = alter_in_tagen(LISTE)
    if alter is None:
        return {"status": "unbekannt", "alter_tage": -1, "letzte": None}

    status = "ueberfaellig" if alter >= PRUEFUNG_UEBERFAELLIG else "ok"
    return {"status": status, "alter_tage": alter,
            "letzte": zeit.isoformat(timespec="seconds")}


def melden(nutzlast):
    if not KONFIG.get("MQTT_HOST"):
        return
    befehl = [
        "mosquitto_pub",
        "-h", KONFIG["MQTT_HOST"], "-p", KONFIG.get("MQTT_PORT", "1883"),
        "-t", TOPIC, "-r",
        "-m", json.dumps(nutzlast, ensure_ascii=False),
    ]
    if KONFIG.get("MQTT_USER"):
        befehl += ["-u", KONFIG["MQTT_USER"], "-P", KONFIG.get("MQTT_PASS", "")]
    subprocess.run(befehl, capture_output=True, text=True)


def main():
    export = export_zustand()
    pruefung = pruefung_zustand()

    nutzlast = {
        "export": export,
        "pruefung": pruefung,
        "geprueft": datetime.now().astimezone().isoformat(timespec="seconds"),
    }

    print(f"Export      {export['status']:12} "
          f"{export['alter_tage']} Tag(e) alt   "
          f"(Warnung ab {EXPORT_WARNUNG}, Fehler ab {EXPORT_FEHLER})")
    print(f"Prüfung     {pruefung['status']:12} "
          f"{pruefung['alter_tage']} Tag(e) alt   "
          f"(überfällig ab {PRUEFUNG_UEBERFAELLIG})")

    if still:
        print()
        print(json.dumps(nutzlast, indent=2, ensure_ascii=False))
    else:
        melden(nutzlast)

    return 0 if export["status"] == "ok" and pruefung["status"] == "ok" else 1


if __name__ == "__main__":
    sys.exit(main())
