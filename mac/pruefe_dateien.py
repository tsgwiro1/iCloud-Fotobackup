#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Gezielte Einzelpruefung: zeigt fuer bestimmte Dateien alles, was ueber ihr
Datum bekannt ist - Fotos-Datum, Importdatum und das echte Datum aus der Datei.

Damit laesst sich klaeren, ob ein verdaechtiger Zeitstempel ein echtes
Aufnahmedatum ist oder ein Importartefakt.

Beispiele:
    ~/.local/pipx/venvs/osxphotos/bin/python pruefe_dateien.py IMG_7043 IMG_7047
    ~/.local/pipx/venvs/osxphotos/bin/python pruefe_dateien.py --datum 2019-06-02

Schreibt NICHTS in die Mediathek.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime

try:
    import osxphotos
except ImportError:
    sys.exit("osxphotos nicht gefunden.")

ECHTE_TAGS = ["RIFF:DateTimeOriginal", "EXIF:DateTimeOriginal", "EXIF:CreateDate",
              "QuickTime:CreationDate", "QuickTime:CreateDate", "XMP:DateCreated",
              "XMP:CreateDate", "IPTC:DateCreated"]
BOGUS = {"1904:01:01", "1970:01:01", "0000:00:00"}


def parse_dt(v):
    if not isinstance(v, str):
        return None
    t = v.strip()
    if t[:10] in BOGUS:
        return None
    t = re.sub(r"[+-]\d{2}:?\d{2}$|Z$", "", t).strip()
    t = re.sub(r"\.\d+$", "", t)
    for f in ("%Y:%m:%d %H:%M:%S", "%Y:%m:%d", "%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S"):
        try:
            d = datetime.strptime(t, f)
        except ValueError:
            continue
        if 1980 < d.year <= datetime.now().year + 1:
            return d
    return None


def naive(d):
    return d.replace(tzinfo=None) if d else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("muster", nargs="*", help="Teile von Dateinamen, z.B. IMG_7043")
    ap.add_argument("--datum", help="Alle Objekte mit diesem Fotos-Datum, z.B. 2019-06-02")
    ap.add_argument("--max", type=int, default=60, help="Hoechstens so viele Treffer")
    args = ap.parse_args()

    if not args.muster and not args.datum:
        sys.exit("Bitte Dateinamen-Muster oder --datum angeben.")

    exiftool = shutil.which("exiftool") or "/opt/homebrew/bin/exiftool"

    print("Lade Mediathek ...")
    db = osxphotos.PhotosDB()
    alle = db.photos(movies=True)

    treffer = []
    for p in alle:
        name = (p.original_filename or p.filename or "")
        if args.datum:
            d = naive(p.date)
            if d and d.strftime("%Y-%m-%d") == args.datum:
                treffer.append(p)
                continue
        if any(m.lower() in name.lower() for m in args.muster):
            treffer.append(p)
    treffer = treffer[:args.max]
    print("  %d Treffer.\n" % len(treffer))
    if not treffer:
        return

    pfade = [p.path for p in treffer if p.path and os.path.exists(p.path)]
    exif = {}
    if pfade and os.path.exists(exiftool):
        proc = subprocess.run([exiftool, "-j", "-G1", "-a", "-time:all", "-Model"] + pfade,
                              capture_output=True, text=True)
        try:
            for e in json.loads(proc.stdout or "[]"):
                src = os.path.realpath(e.get("SourceFile", ""))
                for tag in ECHTE_TAGS:
                    dt = parse_dt(e.get(tag))
                    if dt:
                        exif[src] = (dt, tag, e.get("Model", ""))
                        break
                else:
                    exif[src] = (None, "", e.get("Model", ""))
        except json.JSONDecodeError:
            pass

    print("%-30s %-19s %-19s %-19s %s" % ("Datei", "Fotos zeigt", "importiert", "echt in Datei", "Bewertung"))
    print("-" * 116)
    for p in sorted(treffer, key=lambda x: (x.original_filename or "")):
        name = (p.original_filename or p.filename or "")[:30]
        d, a = naive(p.date), naive(p.date_added)
        echt, tag, modell = exif.get(os.path.realpath(p.path), (None, "", "")) if p.path else (None, "", "")
        if echt and d:
            diff = abs((echt - d).days)
            urteil = "ARTEFAKT (%d Tage daneben)" % diff if diff >= 2 else "stimmt"
        elif not p.path:
            urteil = "Original nicht lokal"
        else:
            urteil = "kein Datum in der Datei"
        print("%-30s %-19s %-19s %-19s %s" % (
            name,
            d.strftime("%Y-%m-%d %H:%M:%S") if d else "-",
            a.strftime("%Y-%m-%d %H:%M:%S") if a else "-",
            echt.strftime("%Y-%m-%d %H:%M:%S") if echt else "-",
            urteil))

    print("\nDie Mediathek wurde nicht veraendert.")


if __name__ == "__main__":
    main()
