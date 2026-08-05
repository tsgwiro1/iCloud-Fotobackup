#!/usr/bin/env python3
"""
pruefe_bestand.py – prüft den Fotobestand auf stille Datenfehler.

Läuft auf dem Zielrechner, braucht den Mac nicht. Für jede Datei werden Prüfsumme
(BLAKE3), Grösse und Änderungszeit gespeichert. Beim nächsten Lauf wird
verglichen:

  Grösse und mtime gleich, Hash gleich    -> in Ordnung
  nicht in der Liste                      -> neu, wird aufgenommen
  Grösse oder mtime geändert              -> legitimer Neuexport, Hash erneuert
  Grösse und mtime gleich, Hash anders    -> BITFAeULE, Alarm
  in der Liste, aber Datei fehlt          -> vermerkt, kein Alarm

Nur der vierte Fall ist echter Schaden: Der Inhalt hat sich geändert, ohne
dass jemand die Datei angefasst hat.

Das Ergebnis geht per MQTT an Home Assistant.

Aufruf:
    ./pruefe_bestand.py            normaler Lauf
    ./pruefe_bestand.py --still    ohne MQTT, nur Protokoll
"""

import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import konfig

KONFIG, KONFIG_PFAD = konfig.laden()

BESTAND = Path(konfig.pflicht(KONFIG, "BESTAND"))
BASIS = Path(__file__).resolve().parent
LISTE = BASIS / "pruefsummen" / "b3.liste"
PROTOKOLLE = BASIS / "protokolle"

# Diese Ordner gehören zur Verwaltung, nicht zum Bestand
AUSGENOMMEN = {"_berichte", "_geloescht"}

TOPIC_STATE = f"{KONFIG.get('MQTT_PRAEFIX', 'fotoexport')}/pruefung/state"
BLOCK = 400  # Dateien pro b3sum-Aufruf

still = "--still" in sys.argv


def naechster_termin():
    """Nächster geplanter Lauf laut Konfiguration.

    Der Wert zeigt nach vorn statt zurück: Steht dort ein Datum in der
    Vergangenheit, ist der Zeitplan stehengeblieben – und das sieht man,
    ohne rechnen zu müssen.
    """
    tag = int(KONFIG.get("PRUEFUNG_TAG", "1"))
    stunde = int(KONFIG.get("PRUEFUNG_STUNDE", "3"))
    jetzt = datetime.now().astimezone()

    if (jetzt.day, jetzt.hour) < (tag, stunde):
        ziel = jetzt.replace(day=tag, hour=stunde, minute=0,
                             second=0, microsecond=0)
    else:
        jahr, monat = jetzt.year, jetzt.month + 1
        if monat > 12:
            jahr, monat = jahr + 1, 1
        ziel = jetzt.replace(year=jahr, month=monat, day=tag,
                             hour=stunde, minute=0, second=0, microsecond=0)
    return ziel.isoformat(timespec="seconds")


def protokolliere(text, datei):
    zeile = f"{datetime.now():%H:%M:%S}  {text}"
    print(zeile, flush=True)
    datei.write(zeile + "\n")
    datei.flush()


def liste_lesen():
    """Liefert {pfad: (hash, groesse, mtime)}."""
    bekannt = {}
    if not LISTE.exists():
        return bekannt
    for zeile in LISTE.read_text().splitlines():
        if not zeile:
            continue
        teile = zeile.split("\t", 3)
        if len(teile) == 4:
            h, groesse, mtime, pfad = teile
            bekannt[pfad] = (h, int(groesse), int(float(mtime)))
    return bekannt


def liste_schreiben(eintraege):
    """Erst daneben schreiben, dann umbenennen – ein Absturz mittendrin
    darf die alte Liste nicht zerstören."""
    tmp = LISTE.with_suffix(".neu")
    with tmp.open("w") as f:
        for pfad in sorted(eintraege):
            h, groesse, mtime = eintraege[pfad]
            f.write(f"{h}\t{groesse}\t{mtime}\t{pfad}\n")
    os.replace(tmp, LISTE)


def dateien_finden():
    """Alle Bestandsdateien, Pfade relativ zu BESTAND."""
    gefunden = []
    for wurzel, ordner, dateien in os.walk(BESTAND):
        rel_wurzel = Path(wurzel).relative_to(BESTAND)
        oberster = rel_wurzel.parts[0] if rel_wurzel.parts else ""
        if oberster in AUSGENOMMEN:
            ordner[:] = []
            continue
        for name in dateien:
            if name.startswith("."):
                continue
            gefunden.append(str((rel_wurzel / name).as_posix()))
    return gefunden


def hashen(pfade):
    """{relpfad: hash} – b3sum in Blöcken, ein Thread."""
    ergebnis = {}
    for start in range(0, len(pfade), BLOCK):
        teil = pfade[start:start + BLOCK]
        lauf = subprocess.run(
            ["b3sum", "--num-threads", "1", "--"] + teil,
            cwd=BESTAND, capture_output=True, text=True,
        )
        for zeile in lauf.stdout.splitlines():
            h, _, pfad = zeile.partition("  ")
            if pfad:
                ergebnis[pfad] = h
    return ergebnis


def melden(nutzlast, log):
    if not KONFIG.get("MQTT_HOST"):
        protokolliere("Kein MQTT_HOST konfiguriert – keine Meldung.", log)
        return
    befehl = [
        "mosquitto_pub",
        "-h", KONFIG["MQTT_HOST"], "-p", KONFIG.get("MQTT_PORT", "1883"),
        "-t", TOPIC_STATE, "-r",
        "-m", json.dumps(nutzlast, ensure_ascii=False),
    ]
    if KONFIG.get("MQTT_USER"):
        befehl += ["-u", KONFIG["MQTT_USER"], "-P", KONFIG.get("MQTT_PASS", "")]
    lauf = subprocess.run(befehl, capture_output=True, text=True)
    if lauf.returncode == 0:
        protokolliere("Ergebnis an Home Assistant gemeldet.", log)
    else:
        protokolliere(f"MQTT fehlgeschlagen: {lauf.stderr.strip()}", log)


def main():
    PROTOKOLLE.mkdir(parents=True, exist_ok=True)
    LISTE.parent.mkdir(parents=True, exist_ok=True)
    protokoll = PROTOKOLLE / f"pruefung_{datetime.now():%Y-%m-%d}.log"

    with protokoll.open("a") as log:
        beginn = time.monotonic()
        protokolliere("=== Bestandsprüfung ===", log)

        bekannt = liste_lesen()
        erster_lauf = not bekannt
        if erster_lauf:
            protokolliere("Keine Liste vorhanden – sie wird jetzt angelegt.", log)
        else:
            protokolliere(f"{len(bekannt)} Einträge in der Liste.", log)

        dateien = dateien_finden()
        protokolliere(f"{len(dateien)} Dateien im Bestand gefunden.", log)

        # Grösse und mtime vorab, das ist billig
        merkmale = {}
        for rel in dateien:
            try:
                st = (BESTAND / rel).stat()
                merkmale[rel] = (st.st_size, int(st.st_mtime))
            except OSError as e:
                protokolliere(f"nicht lesbar: {rel} ({e})", log)

        dateien = list(merkmale)
        protokolliere("Berechne Prüfsummen...", log)
        hashes = hashen(dateien)

        neu, aktualisiert, defekt, unveraendert = [], [], [], 0
        eintraege = {}
        gesamt_bytes = 0

        for rel in dateien:
            groesse, mtime = merkmale[rel]
            gesamt_bytes += groesse
            h = hashes.get(rel)
            if h is None:
                protokolliere(f"keine Prüfsumme erhalten: {rel}", log)
                continue

            eintraege[rel] = (h, groesse, mtime)

            if rel not in bekannt:
                neu.append(rel)
                continue

            alt_h, alt_groesse, alt_mtime = bekannt[rel]
            if (groesse, mtime) != (alt_groesse, alt_mtime):
                if h != alt_h:
                    aktualisiert.append(rel)
                else:
                    unveraendert += 1
            elif h != alt_h:
                defekt.append(rel)
            else:
                unveraendert += 1

        fehlend = sorted(set(bekannt) - set(eintraege))

        liste_schreiben(eintraege)

        dauer = int(time.monotonic() - beginn)
        groesse_gb = round(gesamt_bytes / 1024 ** 3, 1)

        protokolliere("", log)
        protokolliere(f"geprüft       {len(eintraege)}", log)
        protokolliere(f"unverändert   {unveraendert}", log)
        protokolliere(f"neu           {len(neu)}", log)
        protokolliere(f"aktualisiert  {len(aktualisiert)}", log)
        protokolliere(f"fehlend       {len(fehlend)}", log)
        protokolliere(f"BESCHÄDIGT    {len(defekt)}", log)
        protokolliere(f"Bestand       {groesse_gb} GB", log)
        protokolliere(f"Dauer         {dauer} s", log)

        for rel in defekt:
            protokolliere(f"  BESCHÄDIGT: {rel}", log)
        for rel in fehlend[:20]:
            protokolliere(f"  fehlt: {rel}", log)
        if len(fehlend) > 20:
            protokolliere(f"  ... und {len(fehlend) - 20} weitere", log)

        nutzlast = {
            "status": "beanstandet" if defekt else "ok",
            "geprueft": len(eintraege),
            "neu": len(neu),
            "aktualisiert": len(aktualisiert),
            "fehlend": len(fehlend),
            "beanstandungen": len(defekt),
            "defekte": defekt[:20],
            "zeitpunkt": datetime.now(timezone.utc).astimezone().isoformat(
                timespec="seconds"),
            "naechste_pruefung": naechster_termin(),
            "dauer": dauer,
            "groesse_gb": groesse_gb,
            "erster_lauf": erster_lauf,
        }

        if still:
            protokolliere("--still: keine MQTT-Meldung.", log)
            print(json.dumps(nutzlast, indent=2, ensure_ascii=False))
        else:
            melden(nutzlast, log)

        protokolliere("Ende.", log)
        return 1 if defekt else 0


if __name__ == "__main__":
    sys.exit(main())
