# Entscheidungen und Messwerte

Dieses Dokument erklärt, **warum** die Skripte so gebaut sind. Die
Installationsschritte stehen in [installation.md](installation.md).

Alle Zahlen stammen aus einer realen Installation mit rund 48'800 Objekten und
167 GB Bilddaten. Sie sind gemessen, nicht geschätzt – und dort, wo eine
Schätzung danebenlag, steht das auch so da.

---

## Inhalt

- [Was das Backup leistet – und was nicht](#was-das-backup-leistet--und-was-nicht)
- [Zielstruktur](#zielstruktur)
- [Der Exportbefehl](#der-exportbefehl)
- [Platzbedarf auf dem Mac](#platzbedarf-auf-dem-mac)
- [Warum Folgeläufe nicht alles neu laden](#warum-folgeläufe-nicht-alles-neu-laden)
- [Die Freigabe](#die-freigabe)
- [Die Verbindung](#die-verbindung)
- [Bestandsprüfung gegen Bitfäule](#bestandsprüfung-gegen-bitfäule)
- [Löschabgleich und Quarantäne](#löschabgleich-und-quarantäne)
- [Meldung an Home Assistant](#meldung-an-home-assistant)
- [Prüfen](#prüfen)
- [Grenzen](#grenzen)

---

## Was das Backup leistet – und was nicht

**Leistet:** Alle Originale in voller Auflösung, dazu bearbeitete Versionen,
Metadaten als XMP-Beilage. Ordner nach Jahr und Monat. Lesbar mit jedem
Programm, ohne Apple, ohne Abo.

**Leistet nicht:** Eine wiederherstellbare Fotos-Mediathek. Alben,
Gesichtserkennung und Erinnerungen sind im Export nicht enthalten. Ein Import
in eine leere Mediathek ergibt Bilder mit korrekten Daten, aber nicht denselben
Zustand.

Für den Zweck „meine Bilder sind nicht weg, wenn mit iCloud etwas passiert" ist
das genau richtig – und robuster als ein Klon, weil es von keiner Software
abhängt.

### Warum nicht einfach Time Machine?

Bei aktiver Speicheroptimierung liegen die Originale nur teilweise auf dem Mac.
Time Machine würde überwiegend verkleinerte Versionen sichern. Der Export holt
die Originale aus iCloud und legt sie als Dateien ab. Das ist ein anderes
Problem und braucht ein anderes Werkzeug.

---

## Zielstruktur

```
/srv/fotos/
  2005/06/20050617_000135_MVI_1047.avi
  2026/07/20260722_143012_IMG_9184.HEIC
  _geloescht/2026-08/…        Quarantäne
  _berichte/export_2026-08-03.csv
  _berichte/export_2026-08-03.csv.fertig
```

Das Datum steht im Dateinamen, weil es überall sortierbar bleibt und
Namenskollisionen auflöst. `IMG_7047.JPG` und `IMG_7047_2.JPG` sind zwei
verschiedene Aufnahmen von verschiedenen Geräten; mit Zeitstempel davor
kollidieren sie nie.

---

## Der Exportbefehl

```bash
osxphotos export "$MOUNTPOINT" \
  --update \
  --download-missing --use-photokit \
  --directory "{created.year}/{created.mm}" \
  --filename "{created.strftime,%Y%m%d_%H%M%S}_{original_name}" \
  --exportdb "$EXPORTDB" \
  --sidecar XMP \
  --edited-suffix "_bearbeitet" \
  --touch-file \
  --retry 3 \
  --report "…/_berichte/export_$(date +%F).csv" \
  --verbose
```

### `--sidecar XMP` statt `--exiftool`

`--exiftool` schreibt Metadaten in die Bilddateien, startet dafür aber exiftool
pro Datei. Bei knapp 49'000 Objekten kostet das viele Stunden extra.
XMP-Beilagen liest jede ernsthafte Fotosoftware.

### `{created.strftime,…}` statt Einzelfelder

Die erste Fassung benutzte `{created.hh}{created.mi}{created.ss}`. Diese Felder
gibt es nicht; osxphotos heisst sie `created.hour`, `created.min`,
`created.sec`. Ein strftime-Muster ist ohnehin lesbarer als sechs
aneinandergereihte Platzhalter.

### Die Exportdatenbank gehört auf die lokale Platte

Liegt sie auf der Freigabe, schaltet osxphotos von sich aus auf `--ramdb` um –
SQLite über SMB ist zu langsam. Die RAM-Kopie wird aber erst am Ende
zurückgeschrieben. Bricht ein nächtlicher Erstlauf ab, ist der Fortschritt der
Datenbank weg und der nächste Lauf vergleicht alle Objekte von vorn.

Lokal ist sie schnell und überlebt einen Abbruch. Nach jedem erfolgreichen Lauf
legt das Skript eine Kopie nach `_berichte/` auf den Server.

Es gibt sie damit **zweimal, aber nur eine ist in Betrieb**. Die Kopie wird nie
beschrieben und nie gelesen; sie ist Rückfallebene für den Fall, dass die
Mac-Platte stirbt. Sie heisst dort bewusst *nicht* `.osxphotos_export.db`,
damit osxphotos sie nicht versehentlich als aktive Datenbank aufgreift.

Zurückholen, falls je nötig:

```bash
cp "$MOUNTPOINT/_berichte/osxphotos_export.db" "$EXPORTDB"
```

Ohne Datenbank geht nichts verloren – osxphotos baut sie beim nächsten Lauf neu
auf. Es kostet nur einen vollen Vergleichslauf über alle Objekte.

### `--touch-file`

Setzt das Dateidatum aufs Aufnahmedatum. Ohne diese Option trügen alle Dateien
das Exportdatum, und die zeitliche Ordnung wäre nur noch im Dateinamen.

### Kein `--cleanup`

Die Option löscht im Zielordner alles, was nicht mehr zum Lauf gehört. Das
würde versehentliche Löschungen brav mitspiegeln – also genau das, wovor ein
Backup schützen soll. Mehr dazu unter
[Löschabgleich](#löschabgleich-und-quarantäne).

---

## Platzbedarf auf dem Mac

Die Exportdateien gehen direkt auf den Server, nicht auf die lokale Platte. Der
Mac ist Durchlauferhitzer, nicht Zwischenlager.

**Eine Ausnahme gibt es aber.** `--download-missing --use-photokit` fordert
fehlende Originale bei Apple an, und PhotoKit liefert sie nicht als Datenstrom,
sondern legt sie zuerst in die lokale Mediathek. Erst von dort kopiert
osxphotos sie weiter. Die Mediathek wächst während des Laufs also an.

### Eine Schätzung, die um das Fünffache danebenlag

Die Prognose lautete 20 GB. Gemessen wurden **95 GB** – 140 GB frei vorher,
45 GB frei nachher.

Der Denkfehler: „142 GB Mediathek lokal" gegen „162 GB Originale gesamt" zu
stellen und die Differenz als das Fehlende zu lesen. Die 142 GB waren die
Grösse des Mediathek-Bundles – überwiegend optimierte Versionen, Vorschauen und
Datenbanken, kaum Originale. Die kamen also nicht zu 88 % bereits vorhanden
dazu, sondern grösstenteils neu.

Zwei gemessene Zahlen ergeben keine Rechnung, wenn sie Verschiedenes messen.

**Konsequenz für die Planung:** Rechne im schlimmsten Fall mit dem vollen
Umfang deiner Originale als vorübergehendem Zuwachs auf der lokalen Platte.

### Wie macOS den Platz zurückgibt

Nach dem Erstlauf widersprachen sich die Anzeigen – und der Widerspruch ist die
Erklärung:

| Quelle | Wert |
|---|---|
| Finder, Bundle-Grösse | 253.65 GB |
| Systemeinstellungen, Zeile „Fotos" | 45.79 GB |
| Systemeinstellungen, frei | 262.63 GB |
| `df` im Terminal, verfügbar | 45 GB |

Die Differenz von rund 208 GB ist **„löschbar" (purgeable)**: Dateien, die
physisch da sind, die macOS aber wegwerfen darf, weil sie in iCloud liegen.
Genau die Originale, die der Export geholt hat.

Ob macOS diesen Puffer wirklich anfasst, lässt sich mit `mac/platztest.sh`
messen – Platzhalterdateien in 10-GB-Schritten:

```
Start                45 GB
+10 GB → 35 GB       keine Freigabe
+10 GB → 25 GB       keine Freigabe
+10 GB → 15 GB       keine Freigabe
+10 GB →  5 GB       keine Freigabe
   30 s später       13 GB   ← macOS greift ein
Platzhalter gelöscht 53 GB
```

**Der Mechanismus funktioniert, aber erst bei etwa 5 GB und nur häppchenweise.**
macOS gab rund 8 GB frei, nicht mehr – so viel wie akut nötig.

Für die Praxis: Der Platz ist nicht verloren, aber auch nicht bequem abrufbar.
Wer 100 GB für etwas anderes braucht, bekommt sie – aber erst, wenn er sie
tatsächlich anfordert, nicht auf Vorrat.

**Voraussetzung** ist, dass unter Fotos → Einstellungen → iCloud weiterhin
„Mac-Speicher optimieren" gewählt ist und nicht „Originale auf diesen Mac
laden".

**In der Mediathek darf nichts von Hand gelöscht werden.** Das Bundle ist eine
Datenbank mit Dateien daneben; wer darin aufräumt, zerstört die Zuordnung.

### Der Platzwächter und seine Untergrenze

`fotoexport.sh` prüft vor dem Start und danach jede Minute den freien Platz und
beendet den Export sauber, wenn `MINDESTFREI_GB` unterschritten wird.

Die Untergrenze lag zunächst bei 25 GB – also **oberhalb** der Schwelle, ab der
macOS aufräumt. Sie hätte jeden Export abgebrochen, bevor das System überhaupt
Gelegenheit gehabt hätte, Platz zu schaffen. Die beiden Schwellen arbeiteten
gegeneinander.

Voreinstellung ist deshalb **8 GB**: tief genug, dass macOS vorher eingreift,
hoch genug, dass das System nicht strauchelt.

---

## Warum Folgeläufe nicht alles neu laden

Die naheliegende Sorge: Wenn macOS die Originale wieder wegräumt, lädt der
nächste Lauf sie dann alle erneut? Nein. Aus der osxphotos-Dokumentation:

> To determine which files need to be updated, osxphotos stores file signature
> information in the `.osxphotos_export.db` database. The signature includes
> size, modification time, and filename.

Verglichen wird die **Zieldatei auf dem Server**, nicht das Original in der
Mediathek:

1. Signatur passt zur Exportdatenbank → `skipped`, das Original wird nie
   angefasst
2. Nur wenn ein Export nötig ist, wird das Original angefordert – und erst dann
   greift `--download-missing`

Genau darum liegt die Exportdatenbank lokal und wird nach jedem Lauf gesichert:
Sie ist das Gedächtnis, das den erneuten Download verhindert.

Gemessen, zweiter Lauf direkt nach dem Erstlauf:

```
Processed: 48'837 photos, exported: 0, skipped: 50'483,
missing: 0, error: 0
Elapsed time: 0:19:14
Freier Platz: 52 GB vorher, 52 GB nachher
```

Kein Download, kein Zuwachs. Die 19 Minuten sind reine Prüfzeit – rund 100'000
Dateisignaturen über SMB abfragen, Bilder und XMP-Beilagen zusammen. Das ist
die Grundlast jedes Laufs, auch wenn nichts zu tun ist.

Sie wächst mit der **Zahl** der Dateien, nicht mit deren Grösse, und hängt
stark am Netzweg: etwa eine Minute je 5000 Dateien über Gigabit-Kabel, über
WLAN deutlich mehr. Bei einer Sammlung von 5000 Fotos ist der Lauf in gut einer
Minute vorbei.

**Der Preis:** Der Vergleich prüft Grösse, Zeitstempel und Name – *keine*
Prüfsummen. osxphotos sagt das ausdrücklich: „--update does not do a full
comparison (diff) of the files nor does it compare hashes". Eine still
korrumpierte Datei fällt damit nie auf. Dagegen hilft die
[Bestandsprüfung](#bestandsprüfung-gegen-bitfäule).

---

## Die Freigabe

Getestet mit Samba 4.22.10 auf Debian 13.

```ini
[Fotos]
   path = /srv/fotos
   read only = no
   valid users = backup
   force user = backup
   force group = backup
   create mask = 0644
   force create mode = 0644
   directory mask = 0755
   force directory mode = 0755
   vfs objects = catia fruit streams_xattr
   fruit:metadata = stream
   fruit:posix_rename = yes
   fruit:wipe_intentionally_left_blank_rfork = yes
   fruit:delete_empty_adfiles = yes
   ea support = yes
   veto files = /.DS_Store/.TemporaryItems/.Trashes/.fseventsd/.Spotlight-V100/.DocumentRevisions-V100/
   delete veto files = yes
```

**`fruit`** – ohne dieses VFS-Modul streut macOS für jede Datei eine versteckte
`._`-Beilage in den Ordner. Bei knapp 49'000 Objekten wären das 49'000
Fremdkörper zwischen den Bildern. `fruit` legt die Mac-Metadaten stattdessen als
erweiterte Attribute ab.

**`force create mode`** – im ersten Testlauf landeten bearbeitete Versionen und
Videos mit Rechten `600` auf dem Server, die Originale mit `644`. Ursache:
osxphotos übernimmt beim Kopieren die Rechte der Quelldatei, und was PhotoKit
aus iCloud lädt, ist in der Mediathek `600`. **`create mask` allein greift
dagegen nicht – eine Maske erlaubt Bits, sie erzwingt sie nicht.** Sonst hat man
ein Archiv, in dem manche Dateien für andere Konten unlesbar sind, ohne
erkennbares Muster.

**`veto files`** – der erste Finder-Besuch legt prompt eine `.DS_Store` ab.
Samba blendet diese Dateien aus, statt sie über hunderte Jahresordner zu
verteilen.

**`valid users`, kein Gastzugang** – die Freigabe ist beschreibbar. Ein offener
Schreibzugriff im Heimnetz heisst, dass jedes Gerät den Export verändern kann,
auch versehentlich.

### `samba-ad-dc` abschalten

Debian aktiviert diesen Dienst bei der Samba-Installation mit. Er versucht,
einen Active-Directory-Domaincontroller zu starten, scheitert daran und
schreibt bei jedem Boot Fehler ins Log. Für eine Dateifreigabe ist er nutzlos:

```bash
sudo systemctl disable --now samba-ad-dc
```

---

## Die Verbindung

**Kein dauerhafter Mount.** `fotoexport.sh` hängt die Freigabe zu Beginn ein und
am Ende wieder aus – über `trap … EXIT INT TERM`, also auch bei Fehler oder
Abbruch mit Ctrl-C.

Der Grund ist nicht Ordnungsliebe. Ein stehender SMB-Mount überlebt den
Ruhezustand eines MacBooks nicht: Nach dem Aufwachen zeigt der Mountpoint auf
eine tote Verbindung, jeder Zugriff darauf hängt, und der Finder friert mit ein.
Ein Mount, den es nur während des Exports gibt, kann das nicht.

Der Mountpoint liegt unter `~/mnt/`, nicht in `/Volumes`. Damit kommen sich
Skript und Finder nicht in die Quere, wenn nebenher jemand von Hand verbunden
ist.

### Die `mount_smbfs -N`-Falle

Das Passwort steht nicht im Skript, sondern im Schlüsselbund. Der erste Versuch
mit `mount_smbfs -N` scheiterte an „Authentication error".

**`-N` heisst nicht „nimm das gespeicherte Passwort", sondern „frag nicht
nach".** `mount_smbfs` sendet dann ein leeres Passwort. Den Schlüsselbund fragt
es überhaupt nie – im Finder erledigt das eine Schicht darüber (NetAuth). Wer
nur den Finder kennt, hält das für dasselbe. Ist es nicht.

Das Skript holt das Passwort deshalb ausdrücklich mit `security
find-internet-password` und reicht es an `mount_smbfs` weiter.

**Der Preis:** Das Passwort steht für die Dauer des `mount_smbfs`-Aufrufs in
der Prozessliste und ist dort mit `ps` lesbar. Eine Alternative gibt es nicht –
`mount_smbfs` nimmt kein Passwort über die Standardeingabe. Auf einem Rechner
mit einem Benutzer ist das kein echter Zusatzverlust: Wer unter dieser Kennung
Prozesse lesen kann, kommt ohnehin an den Schlüsselbund. Das Skript hält das
Fenster klein und löscht die Variable direkt nach dem Mount.

Sonderzeichen im Passwort werden vorher URL-kodiert, sonst zerlegt ein `@` oder
`/` die Mount-URL.

Weitere Absicherungen: Lockdatei gegen zwei gleichzeitige Läufe,
Erreichbarkeitsprüfung auf Port 445 vor dem Mount, Schreibtest nach dem Mount,
und ein `umount -f` auf einen verwaisten Mount aus einem früheren Absturz.

---

## Bestandsprüfung gegen Bitfäule

`--update` vergleicht Grösse, Zeitstempel und Namen, keine Prüfsummen. Kippt auf
der Platte ein Bit, bleibt die Datei formal unverändert und wird bei jedem
Folgelauf übersprungen. Der Fehler wandert stillschweigend weiter.

`pi/pruefe_bestand.py` prüft deshalb selbst – **vollständig auf dem Server, der
Mac wird dafür nicht gebraucht.**

### Die Unterscheidung, auf die es ankommt

Gespeichert werden **Hash, Grösse und Änderungszeit**. Ohne die letzten beiden
gäbe es Fehlalarme bei jedem legitimen Neuexport:

| Situation | Erkennung | Reaktion |
|---|---|---|
| alles gleich | — | still |
| nicht in der Liste | neu | aufnehmen, still |
| Grösse oder mtime geändert | Neuexport | Hash erneuern, still |
| **Grösse und mtime gleich, Hash anders** | **Bitfäule** | **Alarm** |
| in der Liste, Datei fehlt | gelöscht | protokollieren |

Nur die hervorgehobene Zeile ist echter Schaden: Der Inhalt hat sich geändert,
ohne dass jemand die Datei angefasst hat.

### Warum BLAKE3 statt SHA-256

Gemessen auf einem Raspberry Pi CM4, 211-MB-Datei aus dem Dateicache:

| | Zeit | Durchsatz |
|---|---|---|
| `sha256sum` | 1650 ms | ~128 MB/s |
| `b3sum`, alle Kerne | 194 ms | ~1090 MB/s |
| `b3sum`, 1 Thread | 702 ms | ~300 MB/s |

Der CM4 bringt keine Crypto-Erweiterungen mit (`fp asimd evtstrm crc32 cpuid`,
kein `sha2`), SHA-256 muss also zu Fuss gerechnet werden. BLAKE3 nutzt NEON.

Entscheidend ist die letzte Zeile: **einthreadig immer noch mehr als doppelt so
schnell wie SHA-256 mit voller Kraft.** Damit braucht es keine Drosselung über
`nice` – ein Kern genügt, die übrigen bleiben für andere Dienste frei. Auf
Rechnern mit Crypto-Beschleunigung ist der Abstand kleiner, BLAKE3 bleibt aber
vorn.

Ein Lauf über 100'908 Dateien (167 GB) dauert so **12 Minuten 36 Sekunden** –
gemessen auf einem CM4, einthreadig. Hier zählt die Datenmenge, nicht die
Dateizahl: Es wird jedes Byte gelesen. Grob 4 Minuten je 50 GB auf dieser
Hardware, auf kräftigerer entsprechend weniger.

### Wenn etwas gefunden wird

Eine Prüfsumme sagt nur, dass eine Datei beschädigt ist. Die heile Kopie liegt
in iCloud. Der Weg zurück ist deshalb kurz: **beschädigte Datei auf dem Server
löschen, nächsten Export laufen lassen.** `--update` behandelt eine fehlende
Zieldatei als „muss exportiert werden" und holt sie neu.

---

## Löschabgleich und Quarantäne

Nie automatisch löschen. `pi/quarantaene.py` zeigt an, was verwaist ist; erst
`--verschieben` bewegt die Dateien nach `_geloescht/JJJJ-MM/`. Gelöscht wird
nie.

Das ist der eigentliche Grund für dieses Backup: Ein in Fotos gelöschtes Bild
verschwindet nach 30 Tagen endgültig aus iCloud. Hier bleibt es.

### Warum `osxphotos --cleanup` nicht verwendet wird

Ein Blick in den Quellcode (`cli/export.py`, `cleanup_files`) zeigt, warum:

```python
for dirpath, _, filenames in os.walk(dest_path):
    for filename in filenames:
        if normalize_fs_path(filepath.lower()) not in keepers:
            verbose(f"Deleting [filepath]{filepath}")
            fileutil.unlink(filepath)
```

Alles im Zielordner, was nicht zum aktuellen Lauf gehört, wird gelöscht – auch
`_berichte/` und die Quarantäne selbst. Und zwar wirklich gelöscht, nicht
verschoben.

### Grundlage: der CSV-Bericht

Stattdessen dient der Exportbericht als Wahrheit. Er listet jede Datei, die der
Lauf geschrieben oder als unverändert übersprungen hat – exakt die Menge, die
bleiben soll:

```
verwaist = Dateien auf dem Server − Dateien im Bericht
```

Das läuft direkt auf dem Server und dauert **5 Sekunden** statt der 19 Minuten,
die derselbe Vergleich über SMB vom Mac aus kostet.

Der Pfadpräfix des Mac wird aus dem Bericht selbst abgeleitet (längster
gemeinsamer Pfadanteil), nicht konfiguriert. Damit funktioniert der Abgleich
unabhängig davon, wo und unter welchem Benutzernamen die Freigabe eingehängt
war.

### Drei Sicherungen

**Plausibilitätsgrenze** (`GRENZE_ANTEIL`, Standard 2 %). Gälten mehr Dateien
als verwaist, bricht das Skript ab und verschiebt nichts. Ein abgebrochener
Export schreibt einen unvollständigen Bericht – dann sähe der halbe Bestand wie
Müll aus. Genau in dem Moment, in dem etwas schiefgegangen ist, darf ein
Aufräumwerkzeug nicht besonders gründlich werden.

**Altersgrenze** (`GRENZE_ALTER_TAGE`, Standard 14). Ein veralteter Bericht
kennt neue Fotos nicht und würde sie für Waisen halten.

**Fertigmarkierung.** Diese dritte Sicherung entstand aus einem Beinahe-Unfall
beim Testen. Ein Abgleich während eines laufenden Exports meldete:

```
laut Bericht erwartet  48164
tatsächlich vorhanden  100908
verwaist               52744
ABBRUCH: 52.3% des Bestands gälten als verwaist (Grenze 2%)
```

Die Plausibilitätsgrenze hat gehalten – aber nur, weil der Export erst zur
Hälfte durch war. **osxphotos schreibt den Bericht fortlaufend, nicht am
Ende.** Bei einem zu 99 % fertigen Lauf hätte der Waisenanteil unter 2 %
gelegen, und es wäre tatsächlich verschoben worden.

Deshalb schreibt `fotoexport.sh` nach einem vollständigen Lauf eine Markierung
neben den Bericht:

```
_berichte/export_2026-08-03.csv.fertig
```

Ohne sie verweigert `quarantaene.py` die Arbeit.

### Probeläufe schreiben unter eigenem Namen

Die Fertigmarkierung allein genügte nicht. Ein Trockenlauf über ein einzelnes
Album am selben Tag **überschrieb den Bericht des vorherigen Vollexports** –
osxphotos bildet den Dateinamen aus dem Datum, und beide Läufe fielen auf
denselben Tag. Danach stand im Bericht null statt 100'908 Dateien:

```
laut Bericht erwartet       0
tatsächlich vorhanden  100904
verwaist               100904
ABBRUCH: 100.0% des Bestands gälten als verwaist (Grenze 2%)
```

Zum dritten Mal hat die Plausibilitätsgrenze gehalten. Sie war die einzige
Sicherung, die diesen Fall auffing – Fertigmarkierung und Altersgrenze griffen
beide nicht, weil der Bericht formal frisch und markiert war, nur eben leer.

Seither gilt:

- `--album` oder `--dry-run` → Bericht heisst `probe_JJJJ-MM-TT.csv`
- Nur ein Volllauf schreibt `export_JJJJ-MM-TT.csv` und die Markierung
- Nur ein Volllauf entfernt eine bestehende Markierung zu Beginn
- `quarantaene.py` nimmt den jüngsten Bericht **mit** Markierung, statt am
  jüngsten überhaupt zu scheitern

Die Lehre daraus ist allgemeiner: **Mehrere Sicherungen sind nicht redundant,
solange sie an verschiedenen Stellen ansetzen.** Zwei der drei versagten hier,
die dritte hielt.

---

## Meldung an Home Assistant

Optional. Ohne `MQTT_HOST` in der Konfiguration laufen die Skripte unverändert,
nur eben stumm.

Die Daten-Topics liegen unter dem konfigurierbaren Präfix, das Discovery-Topic
muss dagegen unter `homeassistant/` liegen – das ist in HA fest verdrahtet:

```
<präfix>/pruefung/state                       JSON, retained
<präfix>/waisen/state                         JSON, retained
homeassistant/device/<id>/config              einmalig, retained
```

`melde_geraet.sh` sendet eine **einzige** Discovery-Nachricht, die alle
Entitäten beschreibt (device-based discovery, ab HA 2024.11). In der
MQTT-Integration erscheint dadurch ein Gerät mit elf Entitäten darunter, statt
elf loser Sensoren.

Der Sensor „Naechste Pruefung" zeigt nach vorn statt zurück: Steht dort ein
Datum in der Vergangenheit, ist der Zeitplan stehengeblieben – und das sieht
man, ohne rechnen zu müssen.

**Kein „Last Will".** Ursprünglich vorgesehen, dann verworfen: Ein LWT hängt an
einer bestehenden MQTT-Verbindung. Hier publiziert ein kurzlebiger Prozess
einmal im Monat, es gibt keine dauerhafte Verbindung, an der ein LWT hängen
könnte. Die Rolle des Totmannschalters übernimmt der Zeitstempel plus eine
Automation.

### Zwei Automationen

Beide schreiben eine **Notification in HA**, keine Push-Meldung. Eine
Push-Meldung ist einen Moment lang da und dann weg; eine Notification bleibt
stehen, bis sie quittiert wird.

**Bestand beschädigt** – ausgelöst vom Binärsensor, nennt die betroffenen
Dateien und den Weg zurück.

**Prüfung überfällig** – der Totmannschalter. Prüft täglich, ob der Termin
„Naechste Pruefung" mehr als einen Tag verstrichen ist. Der Tag Karenz fängt
einen Neustart oder eine verzögerte Ausführung ab.

Der Sinn der zweiten Automation ist der unscheinbarere Fall: **Nicht der
gefundene Fehler ist gefährlich, sondern der Auftrag, der stillschweigend nicht
mehr läuft. Dann sieht Stille aus wie Erfolg.**

Vorlagen für beide Automationen liegen in
[home-assistant.md](home-assistant.md).

---

## Prüfen

Dateizahl gegen die Mediathek:

```bash
find "$MOUNTPOINT" -type f ! -name "*.xmp" | wc -l
```

Abweichungen erklärt der CSV-Bericht.

**Einmal jährlich einen zufälligen Jahresordner öffnen und ein paar Bilder und
ein Video ansehen.** Ein Backup, das nie geöffnet wurde, ist eine Vermutung.

Diese Stichprobe ist nicht durch Zählen zu ersetzen. In der beschriebenen
Installation förderte sie zwei Bilder zutage, die im Ordner `1996` lagen und
einen 3D-Drucker zeigten. Die Zahl im Originalnamen war als Unix-Zeitstempel
gelesen worden:

| Zahl im Dateinamen | als Unix-Zeit |
|---|---|
| 838545539 | 1996-07-28 09:18:59 |
| 824023566 | 1996-02-11 07:26:06 |

Exakt die Daten, unter denen die Dateien einsortiert waren. Kein Fehler des
Exports – osxphotos hatte das Aufnahmedatum korrekt aus der Mediathek
übernommen, dort stand es falsch.

**Dateizahlen und Prüfsummen hätten das nie gefunden: Die Dateien sind
technisch einwandfrei, sie stehen nur am falschen Ort.**

Dazu halbjährlich die Platte im Server ansehen – `smartctl -a /dev/…`. Platten
sterben angekündigt, wenn man hinschaut.

---

## Die Berechtigungshürde unter launchd

Der Export von Hand funktioniert sofort. Derselbe Export unter `launchd`
scheitert – und zwar lautlos:

```
touch: …/schreibtest: Operation not permitted
```

**`Operation not permitted`, nicht `Permission denied`.** Der Unterschied ist
die halbe Diagnose: Nicht die Dateirechte verbieten es, sondern macOS. Auf dem
Server ist alles in Ordnung; blockiert wird auf dem Mac.

Der Grund: macOS vergibt Zugriffsrechte **pro Programm**. Was `launchd`
startet, ist nicht das Terminal, dem man den Zugriff erteilt hat. Und ein
Hintergrundprozess bekommt keinen Dialog, in dem er danach fragen könnte.

### Warum eine App-Hülle und nicht `/bin/bash` freigeben

Naheliegend wäre, `/bin/bash` Festplattenvollzugriff zu geben. Aus den
Apple-Entwicklerforen dazu zwei Punkte:

- Festplattenvollzugriff war „only ever *fully* supported for bundled
  executables" – einer nackten ausführbaren Datei lässt er sich gar nicht
  zuverlässig erteilen.
- `/bin/bash` freizugeben wird dort als „excessively large hammer" bezeichnet:
  Danach hat **jedes** Bash-Skript auf dem Rechner vollen Zugriff, auch jedes,
  das man künftig aus Versehen ausführt.

Deshalb `baue_bundle.sh`: Es erzeugt eine minimale App-Hülle, die nichts tut,
ausser `fotoexport.sh --geplant` aufzurufen. Die Berechtigung hängt dann an
diesem einen Vorhaben statt an einem Systeminterpreter.

### Drei Eigenheiten der Hülle

**Fehler werden geschluckt.** Ein AppleScript-Applet zeigt bei einem Fehler
sonst einen Dialog – und ein nächtlicher Lauf, der auf einen Klick wartet,
hängt für immer. Der Preis: Der Rückgabewert an launchd ist immer 0. Deshalb
liest `pruefe_umgebung.sh` das Protokoll statt den launchd-Status; dort steht
ohnehin mehr.

**Das Programm im Bundle wird umbenannt.** Nach dem Übersetzen heisst es
`applet`, und unter diesem Namen fragt macOS später nach Berechtigungen. Ein
Dialog, in dem „applet" um Zugriff auf die Fotomediathek bittet, sieht aus wie
etwas, das man wegklicken sollte. Nach dem Umbenennen muss das Bundle neu
signiert werden, sonst hält macOS es für beschädigt.

**Vier Berechtigungen, jede einmal:** Netzwerkvolume, Fotomediathek, lokales
Netzwerk (ab macOS 15) und Daten anderer Apps. Sie kommen wieder, wenn das
Bundle neu gebaut wird – die neue Signatur ist für macOS ein anderes Programm.

### Eine verweigerte Berechtigung sieht aus wie Abwesenheit

Die Dialoge erscheinen nur in einer Benutzersitzung. Ein LaunchAgent im
Hintergrund bekommt sie **gar nicht erst gezeigt** – macOS verweigert still.

Das ist deshalb tückisch, weil die Verweigerung an einer Stelle auffällt, die
nach etwas völlig anderem aussieht. Ohne die Berechtigung „Lokales Netzwerk"
scheitert schon der Erreichbarkeitstest, und das Skript meldet:

```
192.168.0.x nicht erreichbar – vermutlich ausser Haus.
```

Der Server läuft, antwortet vom Terminal aus in Millisekunden – und trotzdem
steht da eine Diagnose, die einen im Netz suchen lässt statt in den
Berechtigungen. Das Skript kann es nicht besser wissen: Eine stille
Verweigerung ist von einem toten Server nicht zu unterscheiden.

Daraus folgt die Regel: **Nach jedem Neubau des Bundles einmal von Hand
starten**, erst danach der Automatik überlassen. Die Berechtigungen hängen am
Bundle, nicht am Aufrufer – einmal erteilt, gelten sie auch im Hintergrund.

### Der Preis dieser Lösung

Das Bundle ist nicht von Apple beglaubigt. Nach grösseren
macOS-Aktualisierungen kann die Berechtigung erlöschen – für Hilfsprogramme ist
das schon reihenweise passiert. Dann läuft der Export nicht mehr, und **niemand
sagt es einem**, weil ein ausbleibender Lauf keine Meldung erzeugt.

Genau dagegen steht die Überwachung: Der Zielrechner meldet, wenn zu lange kein
Bericht mehr eintrifft, und `pruefe_umgebung.sh` erkennt dieses Fehlerbild und
benennt es.

---

## Grenzen

**Der Mac ist unverzichtbar.** osxphotos holt fehlende Originale über PhotoKit,
ein macOS-Framework, das einen angemeldeten Mac mit Fotos-Berechtigung braucht.
Das lässt sich nicht auf den Server verlegen, auch nicht in einen Container.
Das ist keine Konfigurationsfrage, sondern eine Grenze der Plattform.

Eine serverseitige Alternative wäre `icloudpd`, das die inoffizielle
iCloud-Web-API anspricht. Das löst das Platzproblem, kostet aber regelmässige
Neuanmeldung mit 2FA von Hand, eine API ohne Zusage von Apple, und deutlich
weniger Metadaten – Alben, Personen und Schlagwörter stehen nur in der
Fotos-Datenbank auf dem Mac.

**Der Export ist keine Mediathek.** Siehe ganz oben.

**Ein Backup auf einer Platte ist ein halbes Backup.** Liegen Export und System
auf derselben Platte, trifft ein Defekt beides. Eine zweite Kopie an einem
anderen Ort bleibt sinnvoll.
