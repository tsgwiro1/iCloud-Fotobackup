#!/usr/bin/env python3
"""
quarantaene.py – findet verwaiste Dateien im Fotobestand und stellt sie
unter Quarantäne, statt sie zu löschen.

Verwaist heisst: Die Datei liegt am Ziel, gehörte aber nicht mehr zum
letzten Export. Das passiert, wenn ein Foto in Fotos gelöscht, umdatiert oder
umbenannt wurde.

Grundlage ist der CSV-Bericht des letzten Exports. Er listet jede Datei, die
der Lauf geschrieben oder als unverändert übersprungen hat – das ist genau die
Menge, die bleiben soll.

Bewusst NICHT verwendet: `osxphotos --cleanup`. Diese Option löscht alles im
Zielordner, was nicht zum Lauf gehört – einschliesslich `_berichte/` und der
Quarantäne selbst. Und sie löscht wirklich.

Aufruf:
    ./quarantaene.py                 nur anzeigen, nichts anfassen
    ./quarantaene.py --verschieben   nach _geloescht/JJJJ-MM/ verschieben
    ./quarantaene.py --still         ohne MQTT
"""

import csv
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import konfig

KONFIG, KONFIG_PFAD = konfig.laden()

BESTAND = Path(konfig.pflicht(KONFIG, "BESTAND"))
BERICHTE = BESTAND / "_berichte"
QUARANTAENE = BESTAND / "_geloescht"
BASIS = Path(__file__).resolve().parent
PROTOKOLLE = BASIS / "protokolle"

# Diese Ordner gehören zur Verwaltung und werden nie angetastet
AUSGENOMMEN = {"_berichte", "_geloescht"}

# Mehr Waisen als dieser Anteil heisst: etwas stimmt nicht.
# Ein abgebrochener Export erzeugt einen unvollständigen Bericht – dann sähe
# der halbe Bestand wie Müll aus. Lieber abbrechen als aufräumen.
GRENZE_ANTEIL = float(KONFIG.get("GRENZE_ANTEIL", "0.02"))

# Ist der Bericht älter, ist er keine verlässliche Grundlage mehr
GRENZE_ALTER_TAGE = int(KONFIG.get("GRENZE_ALTER_TAGE", "14"))

TOPIC_STATE = f"{KONFIG.get('MQTT_PRAEFIX', 'fotoexport')}/waisen/state"

verschieben = "--verschieben" in sys.argv
still = "--still" in sys.argv


def protokolliere(text, datei):
    zeile = f"{datetime.now():%H:%M:%S}  {text}"
    print(zeile, flush=True)
    datei.write(zeile + "\n")
    datei.flush()


def neuester_bericht():
    """Der jüngste Bericht, der als vollständig markiert ist.

    Berichte ohne Markierung werden übergangen, nicht bemängelt. Ein Testlauf
    über ein einzelnes Album hinterlässt einen Bericht, der nur einen Teil des
    Bestands kennt – er darf den letzten vollständigen Lauf nicht verdecken
    und den Löschabgleich damit bis zum nächsten Vollexport blockieren.
    """
    berichte = sorted(BERICHTE.glob("export_*.csv"), reverse=True)
    for b in berichte:
        if b.with_suffix(b.suffix + ".fertig").exists():
            return b, len(berichte)
    return None, len(berichte)


def erwartete_dateien(bericht):
    """Alle Pfade aus dem Bericht, relativ zum Bestand.

    Der Bericht enthält die Pfade so, wie der exportierende Rechner sie sieht
    – also mit seinem Mountpoint davor, etwa /Users/name/mnt/fotos/2026/07/…
    Dieser Präfix wird nicht konfiguriert, sondern aus dem Bericht selbst
    abgeleitet: Der längste gemeinsame Pfadanteil aller Einträge ist der
    Mountpoint. Damit funktioniert der Abgleich unabhängig davon, wo und
    unter welchem Benutzernamen die Freigabe eingehängt war.

    Die Annahme trägt, solange der Bestand mehr als einen Unterordner hat.
    Träfe sie nicht zu, wären fast alle Dateien plötzlich verwaist – und
    genau dagegen steht die Plausibilitätsgrenze weiter unten.
    """
    pfade = []
    with bericht.open(newline="") as f:
        for zeile in csv.DictReader(f):
            name = zeile.get("filename", "").strip()
            if name:
                pfade.append(name)

    if not pfade:
        return set(), None

    praefix = os.path.commonpath(pfade) if len(pfade) > 1 \
        else os.path.dirname(pfade[0])

    erwartet = set()
    for p in pfade:
        rel = os.path.relpath(p, praefix)
        if not rel.startswith(".."):
            erwartet.add(Path(rel).as_posix())
    return erwartet, praefix


def vorhandene_dateien():
    gefunden = set()
    for wurzel, ordner, dateien in os.walk(BESTAND):
        rel = Path(wurzel).relative_to(BESTAND)
        oberster = rel.parts[0] if rel.parts else ""
        if oberster in AUSGENOMMEN:
            ordner[:] = []
            continue
        for name in dateien:
            if name.startswith("."):
                continue
            gefunden.add((rel / name).as_posix())
    return gefunden


def melden(nutzlast):
    if not KONFIG.get("MQTT_HOST"):
        return
    befehl = [
        "mosquitto_pub",
        "-h", KONFIG["MQTT_HOST"], "-p", KONFIG.get("MQTT_PORT", "1883"),
        "-t", TOPIC_STATE, "-r",
        "-m", json.dumps(nutzlast, ensure_ascii=False),
    ]
    if KONFIG.get("MQTT_USER"):
        befehl += ["-u", KONFIG["MQTT_USER"], "-P", KONFIG.get("MQTT_PASS", "")]
    subprocess.run(befehl, capture_output=True, text=True)


def main():
    PROTOKOLLE.mkdir(parents=True, exist_ok=True)
    protokoll = PROTOKOLLE / f"waisen_{datetime.now():%Y-%m-%d}.log"

    with protokoll.open("a") as log:
        protokolliere("=== Löschabgleich ===", log)

        # osxphotos schreibt den Bericht fortlaufend, nicht am Ende. Ohne die
        # Markierung würde ein Abgleich während eines laufenden Exports den
        # noch nicht bearbeiteten Teil des Bestands für verwaist halten.
        bericht, anzahl_berichte = neuester_bericht()
        if not bericht:
            if anzahl_berichte:
                protokolliere(
                    f"ABBRUCH: {anzahl_berichte} Bericht(e) vorhanden, aber "
                    "keiner ist als vollständig markiert.", log)
                protokolliere("Entweder läuft ein Export gerade, oder alle "
                              "bisherigen sind abgebrochen oder Teilläufe "
                              "über einzelne Alben.", log)
            else:
                protokolliere("FEHLER: kein Exportbericht in _berichte/ "
                              "gefunden.", log)
            return 2

        alter = (datetime.now() - datetime.fromtimestamp(
            bericht.stat().st_mtime)).days
        protokolliere(f"Bericht: {bericht.name} ({alter} Tage alt)", log)

        if alter > GRENZE_ALTER_TAGE:
            protokolliere(
                f"ABBRUCH: Der Bericht ist älter als {GRENZE_ALTER_TAGE} Tage.", log)
            protokolliere(
                "Erst einen Export laufen lassen, sonst gilt ein veralteter Stand.", log)
            return 2

        erwartet, praefix = erwartete_dateien(bericht)
        if praefix:
            protokolliere(f"Pfadpräfix im Bericht: {praefix}", log)
        vorhanden = vorhandene_dateien()
        waisen = sorted(vorhanden - erwartet)
        fehlend = sorted(erwartet - vorhanden)

        protokolliere(f"laut Bericht erwartet  {len(erwartet)}", log)
        protokolliere(f"tatsächlich vorhanden  {len(vorhanden)}", log)
        protokolliere(f"verwaist               {len(waisen)}", log)
        protokolliere(f"im Bericht, aber weg   {len(fehlend)}", log)

        if fehlend:
            protokolliere("", log)
            protokolliere("Achtung: Dateien fehlen, die der Bericht nennt.", log)
            for f in fehlend[:10]:
                protokolliere(f"  fehlt: {f}", log)

        anteil = len(waisen) / max(len(vorhanden), 1)
        if anteil > GRENZE_ANTEIL:
            protokolliere("", log)
            protokolliere(
                f"ABBRUCH: {anteil:.1%} des Bestands gälten als verwaist "
                f"(Grenze {GRENZE_ANTEIL:.0%}).", log)
            protokolliere(
                "Das deutet auf einen unvollständigen Export hin, nicht auf "
                "gelöschte Fotos. Es wird nichts verschoben.", log)
            if not still:
                melden({
                    "status": "unplausibel",
                    "waisen": len(waisen),
                    "verschoben": 0,
                    "zeitpunkt": datetime.now(timezone.utc).astimezone()
                                 .isoformat(timespec="seconds"),
                    "bericht": bericht.name,
                })
            return 2

        protokolliere("", log)
        for w in waisen:
            protokolliere(f"  verwaist: {w}", log)

        verschoben = 0
        if waisen and verschieben:
            ziel_monat = QUARANTAENE / f"{datetime.now():%Y-%m}"
            protokolliere("", log)
            protokolliere(f"Verschiebe nach {ziel_monat}", log)
            for w in waisen:
                quelle = BESTAND / w
                ziel = ziel_monat / w
                ziel.parent.mkdir(parents=True, exist_ok=True)
                try:
                    shutil.move(str(quelle), str(ziel))
                    verschoben += 1
                    protokolliere(f"  verschoben: {w}", log)
                except OSError as e:
                    protokolliere(f"  FEHLER bei {w}: {e}", log)
            # leere Jahres- und Monatsordner aufräumen
            for wurzel, ordner, dateien in os.walk(BESTAND, topdown=False):
                p = Path(wurzel)
                if p == BESTAND or p.parts[len(BESTAND.parts)] in AUSGENOMMEN:
                    continue
                if not any(p.iterdir()):
                    p.rmdir()
                    protokolliere(f"  leerer Ordner entfernt: "
                                  f"{p.relative_to(BESTAND)}", log)
        elif waisen:
            protokolliere("", log)
            protokolliere("Nur Anzeige. Zum Verschieben:", log)
            protokolliere("  ./quarantaene.py --verschieben", log)

        if not still:
            melden({
                "status": "waisen" if waisen else "ok",
                "waisen": len(waisen),
                "verschoben": verschoben,
                "liste": waisen[:20],
                "zeitpunkt": datetime.now(timezone.utc).astimezone()
                             .isoformat(timespec="seconds"),
                "bericht": bericht.name,
            })

        protokolliere("Ende.", log)
        return 0


if __name__ == "__main__":
    sys.exit(main())
