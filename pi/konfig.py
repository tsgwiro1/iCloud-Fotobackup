#!/usr/bin/env python3
"""
konfig.py – liest die Konfigurationsdatei.

Format ist absichtlich schlicht KEY=WERT, damit dieselbe Datei auch von den
Shell-Skripten auf der Mac-Seite eingelesen werden kann (`. config`).
Deshalb hier keine ini- oder yaml-Bibliothek.
"""

import os
import sys
from pathlib import Path

# Gesucht wird neben dem Skript und im übergeordneten Verzeichnis, damit
# dasselbe Skript aus dem Repository heraus oder installiert laufen kann.
KANDIDATEN = [
    Path(__file__).resolve().parent / "config",
    Path(__file__).resolve().parent.parent / "config",
    Path.home() / "fotobackup" / "config",
]


def laden():
    for pfad in KANDIDATEN:
        if pfad.is_file():
            return _lesen(pfad), pfad
    print("FEHLER: keine Konfigurationsdatei gefunden. Gesucht in:",
          file=sys.stderr)
    for p in KANDIDATEN:
        print(f"  {p}", file=sys.stderr)
    print("Vorlage kopieren: cp config.example config", file=sys.stderr)
    sys.exit(2)


def _lesen(pfad):
    werte = {}
    for zeile in pfad.read_text().splitlines():
        zeile = zeile.strip()
        if not zeile or zeile.startswith("#") or "=" not in zeile:
            continue
        schluessel, wert = zeile.split("=", 1)
        wert = wert.strip()
        # Anführungszeichen entfernen. Die Datei wird auch von Bash per
        # `. config` gelesen, und dort brauchen Werte mit Leerzeichen sie.
        if len(wert) >= 2 and wert[0] == wert[-1] and wert[0] in "\"'":
            wert = wert[1:-1]
        # $HOME und ${HOME} auflösen, damit die Datei auf beiden Seiten
        # gleich aussehen kann
        wert = os.path.expandvars(os.path.expanduser(wert))
        werte[schluessel.strip()] = wert
    return werte


def pflicht(werte, schluessel):
    if schluessel not in werte or not werte[schluessel]:
        print(f"FEHLER: {schluessel} fehlt in der Konfiguration.",
              file=sys.stderr)
        sys.exit(2)
    return werte[schluessel]
