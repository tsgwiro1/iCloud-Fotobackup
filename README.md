# iCloud-Fotobackup 📷

![Version](https://img.shields.io/badge/version-v1.2.0-blue.svg)
![License](https://img.shields.io/badge/license-MIT-green.svg)
![Platform](https://img.shields.io/badge/platform-macOS%20%2B%20Linux-lightgrey.svg)

> Apple-Fotomediathek als normale Dateien auf einen Linux-Server sichern: holt
> die Originale aus iCloud, prüft monatlich auf Bitfäule, löscht nie –
> Verwaistes kommt in Quarantäne.

---

## 📖 Inhalt

- [Das Problem](#-das-problem)
- [Die Lösung](#-die-lösung)
- [Was es leistet – und was nicht](#-was-es-leistet--und-was-nicht)
- [Aufbau](#-aufbau)
- [Schnellstart](#-schnellstart)
- [Die drei Skripte](#-die-drei-skripte)
- [Home Assistant](#-home-assistant)
- [Dokumentation](#-dokumentation)
- [Gemessene Werte](#-gemessene-werte)
- [Haftung](#-haftung)
- [Lizenz](#-lizenz)

---

## 🚨 Das Problem

Wer iCloud-Fotos mit aktivierter **Speicheroptimierung** nutzt, hat auf dem Mac
meist gar nicht seine Fotos – sondern verkleinerte Platzhalter. Die Originale
liegen bei Apple.

Daraus folgt:

1. **Time Machine hilft nicht.** Es sichert brav die Platzhalter.
2. **Ein versehentlich gelöschtes Bild ist nach 30 Tagen endgültig weg** – auf
   allen Geräten gleichzeitig, denn das ist der Sinn von Synchronisation.
3. **Ein Klon der Mediathek hängt an Apple.** Ohne Fotos-App kein Zugriff.

## ✅ Die Lösung

Ein Export mit [osxphotos](https://github.com/RhetTbull/osxphotos), der die
Originale aus iCloud herunterlädt und als **normale Dateien** auf einem
Linux-Server ablegt – nach Jahr und Monat sortiert, mit Aufnahmedatum im
Dateinamen, Metadaten als XMP-Beilage.

Dazu drei Dinge, die ein Kopierskript nicht hat:

| | |
|---|---|
| 🔍 **Bitfäule-Prüfung** | Monatlich BLAKE3 über den Bestand. Erkennt Dateien, deren Inhalt sich geändert hat, ohne dass Größe oder Zeitstempel es täten. |
| 🗑️ **Quarantäne statt Löschen** | Was nicht mehr in der Mediathek ist, wird verschoben, nicht gelöscht. Ein Backup, das Löschungen mitspiegelt, schützt vor nichts. |
| 🏠 **Meldung an Home Assistant** | Optional. Meldet sich, wenn etwas kaputt ist – und auch dann, wenn die Prüfung selbst ausfällt. |

## ⚖️ Was es leistet – und was nicht

**Leistet:** Alle Originale in voller Auflösung, bearbeitete Versionen,
Metadaten als XMP. Lesbar mit jedem Programm, ohne Apple, ohne Abo.

**Leistet nicht:** Eine wiederherstellbare Fotos-Mediathek. Alben,
Gesichtserkennung und Erinnerungen sind nicht enthalten. Ein Import in eine
leere Mediathek ergibt Bilder mit korrekten Daten, aber nicht denselben Zustand.

Für den Zweck „meine Bilder sind nicht weg, wenn mit iCloud etwas passiert" ist
das genau richtig – und robuster als ein Klon, weil es von keiner Software
abhängt.

> ⚠️ **Der Mac bleibt unverzichtbar.** osxphotos holt fehlende Originale über
> PhotoKit, ein macOS-Framework. Das lässt sich nicht auf den Server verlegen,
> auch nicht in einen Container. Der Server macht Ablage, Prüfung und Aufräumen
> – das Holen macht der Mac.

## 🧱 Aufbau

```
Mac                              Linux-Server
────────────────────             ──────────────────────────
fotoexport.sh                    /srv/fotos/
  ├ hängt SMB ein                  ├ 2005/06/…
  ├ osxphotos --update             ├ 2026/07/…
  ├ lädt Fehlendes aus iCloud      ├ _berichte/
  └ hängt wieder aus               └ _geloescht/

                                 pruefe_bestand.py   (monatlich, cron)
                                 quarantaene.py      (nach Bedarf)
                                        │
                                        └── MQTT ──▶ Home Assistant
```

## 🚀 Schnellstart

```bash
git clone https://github.com/tsgwiro1/iCloud-Fotobackup.git
cd iCloud-Fotobackup
cp config.example config
$EDITOR config
./mac/pruefe_umgebung.sh        # sagt, was noch fehlt – ändert nichts
```

Dann der Reihe nach durch **[docs/installation.md](docs/installation.md)** – die
Anleitung ist in der Reihenfolge geschrieben, in der man tatsächlich stolpert,
und jeder Schritt endet mit einer Kontrolle.

Der Kurzweg für Ungeduldige:

```bash
./mac/fotoexport.sh --dry-run --album "Test"   # nichts wird geschrieben
./mac/fotoexport.sh --album "Test"             # ein Album, echt
./mac/fotoexport.sh                            # alles, über Nacht
./mac/fotoexport.sh --status                   # wie weit ist er, darf der nächste
```

Für den Alltag danach – wöchentlicher Lauf per `launchd`, Start und Stopp,
und die Berechtigungshürde, an der Automatisierung meist scheitert:
**[docs/betrieb.md](docs/betrieb.md)**

## 🔧 Die Skripte

### `mac/pruefe_umgebung.sh`

Diagnose beider Seiten: Was ist installiert, ist der Server erreichbar, gibt es
den Schlüsselbund-Eintrag, läuft die Bestandsprüfung, wie viel Platz ist übrig.
Sagt bei jedem Fehlen, was zu tun ist.

**Ändert nichts** – kein Ordner, kein Paket, keine Konfiguration. Nützlich
während der Installation und danach als schneller Gesundheitscheck.

### `mac/fotoexport.sh`

Der Export. Baut die SMB-Verbindung selbst auf und am Ende wieder ab – auch bei
Abbruch, denn ein stehender SMB-Mount überlebt den Ruhezustand eines Laptops
nicht und friert danach den Finder ein.

Enthält einen **Platzwächter**: Die Mediathek wächst während des Laufs, weil
Apple fehlende Originale erst lokal ablegt. Unterschreitet der freie Platz die
Grenze, wird sauber abgebrochen.

`--status` beantwortet ohne Nebenwirkungen die drei Fragen, die während und
nach einem Lauf aufkommen: läuft gerade einer und wie weit ist er, wie ging der
letzte aus, und **darf der nächste geplante überhaupt**. Der dritte Punkt ist
der wichtigste – ein geplanter Lauf steigt still aus, wenn Mindestabstand,
Netzteil oder Server nicht mitspielen, und den Grund sah man bisher erst
hinterher im Protokoll.

Zwischen zwei Läufen:

```
LÄUFT   nichts.

NÄCHSTER geplanter Lauf
        Aufruf    ca. 12:30 (letzter 12:00, alle 30 min)
        Abstand   frei (letzter Lauf 08.08. 16:01)
        Netzteil  FEHLT – der Lauf würde ausgelassen
        Server    192.168.0.6 erreichbar
        Platz     51 GB frei (Untergrenze 8 GB)
```

Die Zeile **Aufruf** ist der Rahmen für alles darunter: Selbst wenn alle
Bedingungen grün sind, passiert bis zum nächsten launchd-Aufruf nichts. Zwischen
„Abstand frei" und dem tatsächlichen Start können deshalb bis zu 30 Minuten
liegen. „ca." ist wörtlich zu nehmen – `StartInterval` zählt nur wache Zeit, nach
einem Ruhezustand holt launchd den verpassten Aufruf beim Aufwachen nach.

Während ein Lauf aktiv ist, rechnet der Block voraus statt zurück:

```
LÄUFT   seit 12:30:56 Uhr, 9 min, PID 14050
        bei Objekt 21503 von 48842 (44 %)
        2389 Objekte/min, noch etwa 11 min

NÄCHSTER geplanter Lauf
        Aufruf    ca. 13:00 (letzter 12:30, alle 30 min) – steigt an der Sperrdatei aus
        Abstand   frei ab ca. 10.08. 08:50 (20 h nach Ende des laufenden Laufs)
        ...
```

Der Aufruf um 13:00 findet statt, trifft aber auf die Sperrdatei und bricht
sofort ab – es gibt keinen zweiten gleichzeitigen Lauf. Und der Mindestabstand
zählt ab dem **Ende** des laufenden Exports, nicht ab dem alten Stempel: Der
wird erst beim Abschluss neu gesetzt.

### `mac/pruefe_dateien.py`

Gezielte Einzelprüfung von Zeitstempeln. Zeigt für bestimmte Dateien das
Fotos-Datum, das Importdatum und das Datum aus der Datei nebeneinander – damit
lässt sich klären, ob ein verdächtiges Aufnahmedatum echt ist oder ein
Importartefakt. **Schreibt nichts in die Mediathek.**

### `pi/pruefe_bestand.py`

Die Bitfäule-Prüfung, läuft auf dem Server ohne Mac. Speichert Hash, Größe und
Änderungszeit je Datei. Alarm gibt es nur, wenn sich der **Hash ändert, während
Größe und Zeitstempel gleich bleiben** – alles andere ist ein legitimer
Neuexport.

### `pi/quarantaene.py`

Der Löschabgleich. Vergleicht den Bestand gegen den Exportbericht und verschiebt
Verwaistes nach `_geloescht/JJJJ-MM/`. Drei Sperren verhindern Unfälle:
Fertigmarkierung des Berichts, Altersgrenze, Plausibilitätsgrenze.

## 🏠 Home Assistant

Optional, über MQTT mit Auto-Discovery. Eine einzige Nachricht legt ein Gerät
mit elf Entitäten an. Details und fertige Automationen:
**[docs/home-assistant.md](docs/home-assistant.md)**

## 📚 Dokumentation

| Datei | Inhalt |
|---|---|
| [docs/installation.md](docs/installation.md) | Schritt für Schritt, mit Kontrollen und typischen Fehlern |
| [docs/betrieb.md](docs/betrieb.md) | Alltag: manuell, per launchd, Start/Stopp, Berechtigungen |
| [docs/entscheidungen.md](docs/entscheidungen.md) | Warum es so gebaut ist – Messwerte, Fallstricke, Irrtümer |
| [docs/home-assistant.md](docs/home-assistant.md) | MQTT, Entitäten, Automationen |
| [CHANGELOG.md](CHANGELOG.md) | Was sich je Version geändert hat, und warum |

## 📊 Gemessene Werte

> ⚠️ **Alles aus einer Installation**, nicht aus einer Messreihe: ~48'800
> Objekte, 100'908 Dateien (Bilder plus XMP), 167 GB, Raspberry Pi CM4 an
> Gigabit-Kabel. Bei anderer Sammlungsgrösse, über WLAN oder auf anderer
> Hardware sieht es anders aus – die Faustregeln in der letzten Spalte helfen
> beim Umrechnen.

| | gemessen | skaliert mit |
|---|---|---|
| Erstlauf | 12 h 06 min | Objektzahl, ~1 h je 4000 Objekte |
| Folgelauf ohne Änderungen | 20 min – aber siehe unten | Datei**zahl**, ~1 min je 5000 Dateien |
| Bestandsprüfung | 12 min 36 s auf **einem** Kern | Daten**menge**, ~4 min je 50 GB |
| Löschabgleich | 5 s | Dateizahl, läuft lokal auf dem Server |
| `b3sum` vs. `sha256sum` auf CM4 | 8× schneller, einthreadig noch 2× | — |
| Vorübergehender Platzbedarf auf dem Mac | **95 GB** – geschätzt waren 20 | Umfang der Originale |

Der Erstlauf hängt an Apple, nicht an der Leitung: Die Objekte kommen einzeln
über PhotoKit, und der Durchsatz bestimmt sich aus der Latenz je Datei. Eine
schnellere Internetverbindung hilft kaum.

> ⚠️ **`ProcessType` in der `.plist` entscheidet über den Faktor 3.5.**
> Dieselbe Arbeit, dasselbe Ergebnis, nur anders gestartet:
>
> | | Objekte/min | Laufzeit |
> |---|---|---|
> | `ProcessType Background` | 751 | 64–73 min |
> | `ProcessType Standard` | 2626 | **20 min** |
>
> `Background` klingt nach der richtigen Wahl für einen nächtlichen
> Wartungslauf, lässt launchd aber die I/O aktiv drosseln – und dieser Lauf
> besteht praktisch nur aus I/O. Die mitgelieferte Vorlage steht deshalb auf
> `Standard`. Wer sie ändert, ändert die Laufzeit um das Dreieinhalbfache.

Die letzte Zeile ist der lehrreichste Wert und in
[docs/entscheidungen.md](docs/entscheidungen.md#eine-schätzung-die-um-das-fünffache-danebenlag)
auseinandergenommen.

## ⚠️ Haftung

Diese Skripte verschieben und lesen Dateien; `quarantaene.py` bewegt Daten
innerhalb des Zielordners. Sie löschen nichts – aber sie sind auch keine
geprüfte Software.

**Teste jeden Schritt zuerst mit `--dry-run` und einem kleinen Album.** Die
Verantwortung für deine Daten bleibt bei dir. Nutzung auf eigene Gefahr, ohne
Gewähr für Vollständigkeit oder Fehlerfreiheit.

Und der Satz, der für jedes Backup gilt: **Ein Backup, das nie geöffnet wurde,
ist eine Vermutung.** Sieh dir einmal im Jahr ein paar Bilder an.

## 📄 Lizenz

MIT – siehe [LICENSE](LICENSE).
