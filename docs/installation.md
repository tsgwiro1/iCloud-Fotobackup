# Installation

Schritt für Schritt, in der Reihenfolge, in der es sinnvoll ist. Jeder Schritt
endet mit einer Kontrolle – wenn die nicht stimmt, hat es keinen Zweck,
weiterzumachen.

Rechne mit **ein bis zwei Stunden** für die Einrichtung und **einer Nacht** für
den ersten Export.

> **Jederzeit hilfreich:** `./mac/pruefe_umgebung.sh` sagt, wo du stehst und was
> als Nächstes fehlt. Das Skript ändert nichts – es liest nur und vergleicht.
> Nach jedem Schritt einmal aufrufen erspart das Suchen im Text.

---

## Inhalt

1. [Voraussetzungen](#1-voraussetzungen)
2. [Platzbedarf abschätzen](#2-platzbedarf-abschätzen)
3. [Server: Samba einrichten](#3-server-samba-einrichten)
4. [Mac: osxphotos installieren](#4-mac-osxphotos-installieren)
5. [Konfiguration anlegen](#5-konfiguration-anlegen)
6. [Erste Verbindung und Schlüsselbund](#6-erste-verbindung-und-schlüsselbund)
7. [Trockenlauf](#7-trockenlauf)
8. [Testlauf über ein Album](#8-testlauf-über-ein-album)
9. [Der Erstlauf](#9-der-erstlauf)
10. [Ergebnis prüfen](#10-ergebnis-prüfen)
11. [Server: Bestandsprüfung einrichten](#11-server-bestandsprüfung-einrichten)
12. [Optional: Home Assistant](#12-optional-home-assistant)
13. [Löschabgleich](#13-löschabgleich)

---

## 1. Voraussetzungen

**Auf dem Mac:**

- macOS mit eingerichteter iCloud-Fotomediathek
- Genug freier Platz – siehe [Schritt 2](#2-platzbedarf-abschätzen)
- Netzteil, und bei einem Laptop: der Deckel muss offen bleiben können

**Auf dem Server** (Raspberry Pi, NAS, beliebiger Linux-Rechner):

- Platz für den vollen Umfang deiner Originale
- Ein Benutzerkonto und SSH-Zugang
- Verkabeltes Netzwerk empfohlen

**Dazwischen:** Beide Geräte im selben Netz.

---

## 2. Platzbedarf abschätzen

**Auf dem Server** brauchst du den vollen Umfang deiner Originale. In der
Fotos-App unter Einstellungen → Allgemein steht die Zahl der Objekte; die
tatsächliche Grösse zeigt osxphotos später an.

**Auf dem Mac** – und das ist der Punkt, den man leicht unterschätzt – wächst
die Mediathek während des Exports. Fehlende Originale werden von Apple zuerst
in die lokale Mediathek geladen und erst von dort weiterkopiert.

> **Rechne im schlimmsten Fall mit dem vollen Umfang deiner Originale als
> vorübergehendem Zuwachs.** In der Referenzinstallation waren 20 GB
> geschätzt – es wurden 95 GB. Warum, steht in
> [entscheidungen.md](entscheidungen.md#eine-schätzung-die-um-das-fünffache-danebenlag).

Der Platzwächter im Skript bricht ab, bevor die Platte volläuft. Danach kann
man den Speicher optimieren lassen und denselben Aufruf wiederholen.

---

## 3. Server: Samba einrichten

```bash
sudo apt update
sudo apt install samba
```

Debian aktiviert dabei `samba-ad-dc` mit. Der Dienst versucht, einen
Active-Directory-Domaincontroller zu starten, scheitert und schreibt bei jedem
Boot Fehler ins Log:

```bash
sudo systemctl disable --now samba-ad-dc
```

Zielordner anlegen (Pfad und Benutzer nach Bedarf anpassen):

```bash
sudo mkdir -p /srv/fotos/_berichte /srv/fotos/_geloescht
sudo chown -R "$USER:$USER" /srv/fotos
sudo chmod 755 /srv/fotos
```

Freigabe an `/etc/samba/smb.conf` anhängen – `valid users`, `force user` und
`force group` auf dein Konto setzen:

```ini
[Fotos]
   comment = Fotoexport
   path = /srv/fotos
   browseable = yes
   read only = no
   valid users = DEIN_BENUTZER
   force user = DEIN_BENUTZER
   force group = DEIN_BENUTZER
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

Die einzelnen Optionen sind in
[entscheidungen.md](entscheidungen.md#die-freigabe) begründet. `fruit` und
`force create mode` sind nicht optional, wenn das Archiv sauber bleiben soll.

SMB-Passwort setzen – **das ist ein eigenes Passwort, nicht das
Anmeldepasswort:**

```bash
sudo smbpasswd -a DEIN_BENUTZER
sudo systemctl restart smbd
```

Optional, damit der Server im Finder unter „Netzwerk" auftaucht:

```bash
sudo apt install avahi-daemon
```

**Kontrolle:**

```bash
testparm -s | grep -A5 "\[Fotos\]"
systemctl is-active smbd
```

---

## 4. Mac: osxphotos installieren

```bash
brew install pipx
pipx install osxphotos
osxphotos --version
```

Beim ersten Aufruf fragt macOS nach Zugriff auf die Fotos-Mediathek. Ohne diese
Erlaubnis geht nichts.

> **Die Erlaubnis gilt pro aufrufender Anwendung, nicht pro Befehl.** Wer
> osxphotos im Terminal freigibt und es später aus einer anderen Umgebung
> startet – iTerm, ein Automatisierungswerkzeug, ein Editor – bekommt dort:
>
> ```
> Error: could not get authorization to access Photos library
> ```
>
> Das ist kein Fehler der Skripte. Die betreffende Anwendung muss unter
> Systemeinstellungen → Datenschutz & Sicherheit → Fotos freigegeben werden.
> Für spätere automatische Läufe gilt dasselbe: Was `launchd` startet, braucht
> eine eigene Freigabe.

**Kontrolle:**

```bash
osxphotos info
```

Zeigt die Zahl der Objekte in deiner Mediathek.

---

## 5. Konfiguration anlegen

```bash
cp config.example config
```

Anpassen müssen alle: `SERVER`, `SHARE`, `SMB_USER`, `BESTAND`. Der Rest hat
brauchbare Voreinstellungen.

> **Werte mit Leerzeichen gehören in Anführungszeichen.** Die Datei wird von
> Bash eingelesen; ohne Anführungszeichen hält die Shell das zweite Wort für
> einen Befehl.

Dieselbe Datei auf den Server kopieren – dort werden nur `BESTAND` und die
MQTT-Werte gebraucht:

```bash
scp config BENUTZER@SERVER:~/fotobackup/config
```

**Kontrolle:**

```bash
( . ./config && echo "$SERVER $SHARE $BESTAND" )
```

---

## 6. Erste Verbindung und Schlüsselbund

Dieser Schritt lässt sich nicht überspringen und nicht automatisieren.

Im Finder ⌘K drücken, `smb://SERVER/Fotos` eingeben, mit dem SMB-Benutzer
anmelden und **„Passwort im Schlüsselbund sichern" ankreuzen**. Danach die
Verbindung wieder auswerfen – das Skript baut seine eigene auf.

> **Warum das nötig ist:** `mount_smbfs` fragt den Schlüsselbund nicht von sich
> aus. Und `-N` heisst nicht „nimm das gespeicherte Passwort", sondern „frag
> nicht nach" – dann wird ein leeres Passwort gesendet. Das Skript holt es
> deshalb ausdrücklich mit `security`, und dafür muss ein Eintrag existieren.

Beim ersten Skriptlauf fragt macOS einmalig, ob `security` auf den Eintrag
zugreifen darf. **„Immer erlauben"** wählen, sonst kommt der Dialog bei jedem
automatischen Lauf wieder und blockiert ihn.

Falls du keinen Finder-Eintrag willst, geht auch:

```bash
security add-generic-password -a SMB_BENUTZER -s fotobackup -T /usr/bin/security -w
```

---

## 7. Trockenlauf

```bash
./mac/fotoexport.sh --dry-run --album "NAME_EINES_KLEINEN_ALBUMS"
```

Es wird nichts geschrieben. Was du sehen willst:

```
Verbunden: /Users/…/mnt/fotos
Exported … to …/2026/07/20260725_215736_IMG_6128.JPG
Verbindung wird getrennt.
```

**Typische Fehler an dieser Stelle:**

| Meldung | Ursache |
|---|---|
| `antwortet nicht auf Port 445` | Server aus, falsche Adresse, oder smbd läuft nicht |
| `kein Passwort im Schlüsselbund gefunden` | Schritt 6 fehlt |
| `Authentication error` | Falsches Passwort, oder `smbpasswd` nie gesetzt |
| `kein Schreibzugriff auf die Freigabe` | `valid users` oder Dateirechte am Zielordner |
| `could not get authorization to access Photos library` | Die aufrufende Anwendung hat keine Fotos-Berechtigung (siehe Schritt 4) |

---

## 8. Testlauf über ein Album

Jetzt derselbe Lauf, aber echt:

```bash
./mac/fotoexport.sh --album "NAME_EINES_KLEINEN_ALBUMS"
```

Wähle ein Album, das **mindestens ein Video und ein bearbeitetes Bild**
enthält. Genau dort zeigen sich Probleme.

**Kontrolle auf dem Server:**

```bash
ls -l --time-style=long-iso /srv/fotos/*/*/
```

Zu prüfen:

- Die Zeitstempel zeigen das **Aufnahmedatum**, nicht das Exportdatum
- Alle Dateien haben `644`, keine `600` (sonst fehlt `force create mode`)
- Keine `._`-Dateien und keine `.DS_Store` (sonst fehlt `fruit` oder `veto files`)
- Zu jedem Bild liegt eine `.xmp`-Beilage

Im Protokoll sollte `missing: 0` stehen – dann hat der Download aus iCloud
funktioniert. Das ist die wichtigste Zeile des ganzen Testlaufs.

---

## 9. Der Erstlauf

```bash
./mac/fotoexport.sh
```

- **Am Netzteil**, Deckel offen. `caffeinate` verhindert nur den
  Leerlauf-Schlaf; ein Laptop mit geschlossenem Deckel schläft trotzdem.
- **Dauer:** nicht die Bandbreite entscheidet, sondern Apple. Die Objekte
  werden einzeln über PhotoKit geholt, und der Durchsatz hängt an der Latenz
  je Datei – eine schnellere Leitung hilft kaum.

  In der Referenzinstallation: **12 Stunden für 48'800 Objekte / 167 GB**, also
  grob eine Stunde je 4000 Objekte. Wer 5000 Fotos hat, ist in gut einer Stunde
  durch. Ein Anhaltspunkt, keine Zusage: Wie viel bereits lokal liegt und wie
  bereitwillig Apple gerade liefert, schwankt.
- **Ein Abbruch ist unkritisch.** Einfach denselben Aufruf wiederholen, ohne
  Zusatzangabe – das Skript übergibt osxphotos intern immer `--update` und
  macht nur, was noch fehlt. Einen Fortsetzen-Schalter gibt es nicht, weil es
  keinen braucht.
- Bricht der Platzwächter ab: in den Systemeinstellungen den Speicher
  optimieren lassen, dann erneut starten.

Fortschritt in einem zweiten Fenster:

```bash
./mac/fotoexport.sh --status -w
```

---

## 10. Ergebnis prüfen

```
Processed: … photos, exported: …, missing: 0, error: 0
```

`missing: 0` und `error: 0` sind das Ziel. Dann:

```bash
find ~/mnt/fotos -type f ! -name "*.xmp" | wc -l
```

Sollte nahe an der Objektzahl liegen – etwas darüber ist normal, weil
bearbeitete Versionen zusätzlich abgelegt werden.

**Und dann sieh dir Bilder an.** Öffne einen zufälligen Jahresordner, schau ein
paar Fotos und ein Video an. Ein Backup, das nie geöffnet wurde, ist eine
Vermutung – und genau dieser Schritt findet Fehler, die keine Zahl zeigt.

---

## 11. Server: Bestandsprüfung einrichten

Auf dem Server:

```bash
sudo apt install b3sum
mkdir -p ~/fotobackup
```

Die Dateien aus `pi/` dorthin kopieren, dazu die `config`:

```bash
scp pi/*.py pi/*.sh config BENUTZER@SERVER:~/fotobackup/
```

Ersten Lauf von Hand starten – er legt die Prüfsummenliste an:

```bash
cd ~/fotobackup
chmod +x *.py *.sh
./pruefe_bestand.py
```

Dauer in der Referenzinstallation: **13 Minuten für 100'000 Dateien / 167 GB**
auf einem Raspberry Pi CM4, auf einem einzigen Kern.

Hier begrenzt die Datenmenge, nicht die Dateizahl – es wird ja jedes Byte
gelesen. Als Anhaltspunkt rund 4 Minuten je 50 GB auf einem CM4; auf
kräftigerer Hardware entsprechend weniger.

Dann monatlich per cron:

```bash
crontab -e
```

```
0 3 1 * * /home/BENUTZER/fotobackup/pruefe_bestand.py >> /home/BENUTZER/fotobackup/protokolle/cron.log 2>&1
```

Der Zeitplan muss zu `PRUEFUNG_TAG` und `PRUEFUNG_STUNDE` in der Konfiguration
passen – daraus wird der gemeldete Termin der nächsten Prüfung berechnet.

---

## 12. Optional: Home Assistant

Nur nötig, wenn du Meldungen willst. Ohne `MQTT_HOST` läuft alles unverändert,
nur stumm.

```bash
sudo apt install mosquitto-clients
```

MQTT-Werte in der `config` eintragen, dann das Gerät anmelden:

```bash
./melde_geraet.sh
```

In Home Assistant erscheint unter Einstellungen → Geräte → MQTT ein neues Gerät
mit elf Entitäten. Sie stehen auf `unknown`, bis der erste Lauf Daten liefert:

```bash
./pruefe_bestand.py
./quarantaene.py
```

Die beiden empfohlenen Automationen stehen in
[home-assistant.md](home-assistant.md).

---

## 13. Löschabgleich

Zeigt an, welche Dateien auf dem Server nicht mehr zur Mediathek gehören:

```bash
./quarantaene.py
```

Verschieben – nach Sichtung der Liste:

```bash
./quarantaene.py --verschieben
```

Die Dateien landen unter `_geloescht/JJJJ-MM/` mit erhaltener Ordnerstruktur.
**Gelöscht wird nie.**

Das Skript verweigert die Arbeit, wenn:

- der Bericht nicht als vollständig markiert ist (Export läuft noch oder ist
  abgebrochen)
- der Bericht älter als `GRENZE_ALTER_TAGE` ist
- mehr als `GRENZE_ANTEIL` des Bestands verwaist wäre

Alle drei Sperren sind Absicht. Die Begründungen stehen in
[entscheidungen.md](entscheidungen.md#drei-sicherungen).

---

## Danach

Der Export läuft nicht von selbst – er braucht eine angemeldete Sitzung. Wie er
im Alltag bedient und per `launchd` eingeplant wird, steht in
**[betrieb.md](betrieb.md)**: manuelle Läufe, Zeitplan, Start und Stopp, und
die Berechtigungshürde, an der die Automatisierung meistens scheitert.

Die Bestandsprüfung auf dem Server läuft dagegen ab jetzt von selbst.
