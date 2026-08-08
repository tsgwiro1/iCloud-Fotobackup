# Betrieb

Was nach der [Installation](installation.md) im Alltag zu tun ist.

Die Aufgabenteilung: **Der Server erledigt seinen Teil von selbst** –
Bestandsprüfung monatlich per cron. **Der Export vom Mac läuft nicht von
selbst**, weil er eine angemeldete Sitzung braucht. Er wird entweder von Hand
gestartet oder per `launchd` eingeplant.

---

## Inhalt

- [Manuelle Ausführung](#manuelle-ausführung)
- [Automatisch mit launchd](#automatisch-mit-launchd)
- [Die Hürde: Berechtigungen](#die-hürde-berechtigungen)
- [Start, Stopp, Kontrolle](#start-stopp-kontrolle)
- [Automatik wieder entfernen](#automatik-wieder-entfernen)
- [Wenn der Mac geschlafen hat](#wenn-der-mac-geschlafen-hat)
- [Auf dem Server](#auf-dem-server)
- [Regelmässige Handgriffe](#regelmässige-handgriffe)

---

## Manuelle Ausführung

### Vollständiger Export

```bash
cd ~/repos/iCloud-Fotobackup
./mac/fotoexport.sh
```

Das ist der Normalfall. Was passiert:

1. Prüft, ob der Server auf Port 445 antwortet
2. Hängt die Freigabe unter `MOUNTPOINT` ein
3. Startet den Platzwächter
4. Exportiert alles Neue und Geänderte
5. Schreibt `_berichte/export_JJJJ-MM-TT.csv` und die Fertigmarkierung
6. Sichert die Exportdatenbank auf den Server
7. Trennt die Verbindung – auch bei Fehler oder Ctrl-C

**Dauer:** Auch wenn nichts zu tun ist, kostet jeder Lauf Zeit – osxphotos
vergleicht die Signatur **jeder einzelnen Datei** am Ziel, und das über das
Netz.

In der Referenzinstallation sind das **rund 20 Minuten für 100'000 Dateien**
(50'000 Bilder plus ebenso viele XMP-Beilagen) über Gigabit-Kabel. Als
Anhaltspunkt: etwa eine Minute je 5000 Dateien.

Was den Wert verschiebt:

| | |
|---|---|
| **Zahl** der Dateien | linear – nicht deren Grösse |
| WLAN statt Kabel | deutlich langsamer, jede Abfrage kostet Latenz |
| schwacher Server | ein Raspberry Pi antwortet gemächlicher als ein NAS |

Wer 5000 Fotos hat, ist in gut einer Minute durch. Mit neuen oder bearbeiteten
Fotos kommt die Übertragungszeit dazu – die hängt dann an der Dateigrösse und
daran, wie viel Apple aus iCloud nachliefern muss.

**Am Netzteil, Deckel offen.** `caffeinate` verhindert nur den
Leerlauf-Schlaf; ein Laptop mit geschlossenem Deckel schläft trotzdem.

### Probeläufe

```bash
./mac/fotoexport.sh --dry-run                 # nichts wird geschrieben
./mac/fotoexport.sh --album "Urlaub 2026"     # nur ein Album
./mac/fotoexport.sh --dry-run --album "Test"  # beides
```

Probeläufe schreiben ihren Bericht als `probe_JJJJ-MM-TT.csv` und setzen keine
Fertigmarkierung. Sie können den Löschabgleich also nicht durcheinanderbringen.

### Fortschritt beobachten

In einem zweiten Fenster:

```bash
./mac/fotoexport.sh --status      # einmalige Auskunft
./mac/fotoexport.sh --status -w   # aktualisiert sich alle 60 Sekunden
```

Zeigt, bei welchem Objekt von wie vielen der Lauf steht, wie schnell er
vorankommt und wie lange es noch etwa dauert – dazu den letzten
abgeschlossenen Export und die Bedingungen für den nächsten geplanten Lauf.
Fasst nichts an und stört den Export nicht.

Oder direkt ins Protokoll:

```bash
tail -f ~/Library/Logs/fotoexport/export_$(date +%F).log
```

### Abbrechen

Ctrl-C genügt. Das Skript hängt die Freigabe aus und räumt auf.

**Der nächste Aufruf setzt fort – ohne Zusatzangabe.** Einfach wieder
`./mac/fotoexport.sh`, wie beim ersten Mal. Das Skript übergibt osxphotos
intern immer `--update`; jeder Lauf vergleicht also gegen die Exportdatenbank
und macht nur, was fehlt. Ein Fortsetzen-Schalter ist deshalb weder nötig noch
vorhanden.

---

## Automatisch mit launchd

### Warum LaunchAgent und nicht LaunchDaemon

Der Export braucht den **Schlüsselbund des angemeldeten Benutzers** (für das
SMB-Passwort) und dessen **Fotos-Berechtigung**. Ein LaunchDaemon läuft ohne
Benutzersitzung und hat weder das eine noch das andere. Er würde zuverlässig
scheitern – und zwar still.

### Der Modus `--geplant`

Der LaunchAgent ruft das Skript mit `--geplant` auf und fragt **alle 30 Minuten
nach**. Das klingt viel, ist aber der Kern der Sache.

**Warum kein fester Termin.** Ein Laptop wird im Akkubetrieb aufgeklappt und
erst irgendwann später eingesteckt. Ein einziger Termin am Tag träfe fast immer
den Moment, in dem gerade kein Netzteil dranhängt – der Export liefe dann
praktisch nie, und niemand würde es merken. Häufiges Nachfragen kostet
dagegen nichts: Die meisten Aufrufe enden nach Sekundenbruchteilen.

Bei jedem Aufruf wird der Reihe nach geprüft:

1. **Ist seit dem letzten erfolgreichen Lauf genug Zeit vergangen?**
   (`MINDESTABSTAND_STUNDEN`, Standard 20) Wenn nein: sofort Schluss, ohne
   Logeintrag – sonst würde das Protokoll zulaufen.
2. **Netzteil angeschlossen?** Wenn nein: verschoben. Diese Sperre lässt sich
   mit `NETZTEIL_NOETIG=nein` abschalten – siehe unten.
3. **Server erreichbar?** Wenn nein: verschoben, man ist ausser Haus.

Alles endet mit **Rückgabewert 0**, nicht mit einem Fehler. Ein ausgelassener
Lauf ist kein Defekt, und weder launchd noch das Prüfskript sollen deswegen
Alarm schlagen.

Effektiv heisst das: **Der Export startet, sobald der Mac am Strom hängt und im
Heimnetz ist – höchstens aber einmal pro Tag.**

Von Hand aufgerufen (`./mac/fotoexport.sh` ohne `--geplant`) gelten diese
Sperren nicht – da entscheidest du selbst.

Warum 20 Stunden und nicht 24: Sonst wandert der Zeitpunkt von Tag zu Tag nach
hinten, weil sich die Wartezeit bis zum nächsten passenden Moment aufaddiert.

### Auch im Akkubetrieb laufen lassen

`NETZTEIL_NOETIG=nein` in der Konfiguration lässt geplante Läufe unabhängig vom
Netzteil zu. Vorgabe ist `ja`, denn ein voller Lauf hält Platte, Netz und
PhotoKit eine Weile beschäftigt.

Ein Vorbehalt gehört dazu: `caffeinate -s`, das den Ruhezustand des ganzen
Systems verhindert, **wirkt laut Apple nur am Netzteil**. Im Akkubetrieb bleibt
`caffeinate -i` gegen den Leerlauf-Ruhezustand – der Mac bleibt also wach,
solange der Deckel offen ist. Zugeklappt schläft er trotzdem ein und der Lauf
bricht ab. Der nächste setzt ihn fort, aber der Bericht des abgebrochenen
Laufs bleibt ohne Fertigmarkierung und taugt nicht für den Löschabgleich.

Für einen einzelnen Lauf ausserhalb der Reihe ist der direkte Aufruf meist
einfacher: `./mac/fotoexport.sh` ohne `--geplant` kennt weder Netzteil- noch
Abstandssperre. Über die Automatik geht es nur, wenn es gerade darum geht, das
Bundle selbst zu erproben.

### Einrichten

```bash
mkdir -p ~/Library/LaunchAgents ~/Library/Logs/fotoexport
sed "s|/Users/BENUTZER|$HOME|g" mac/local.fotobackup.export.plist.example \
  > ~/Library/LaunchAgents/local.fotobackup.export.plist
plutil -lint ~/Library/LaunchAgents/local.fotobackup.export.plist
```

Der Pfad zum Skript muss stimmen – prüfen mit:

```bash
plutil -p ~/Library/LaunchAgents/local.fotobackup.export.plist | grep -A3 ProgramArguments
```

Voreingestellt ist eine Nachfrage **alle 30 Minuten** (`StartInterval 1800`),
gedrosselt durch `MINDESTABSTAND_STUNDEN` in der Konfiguration.

Laden:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.fotobackup.export.plist
```

**Kontrolle:**

```bash
launchctl print gui/$(id -u)/local.fotobackup.export | head -20
```

Zeigt Status, nächsten Termin und den letzten Rückgabewert.

---

## Die Hürde: Berechtigungen

Das ist der Punkt, an dem die Automatisierung meistens scheitert – und zwar
lautlos. Er ist der Grund für die App-Hülle aus dem vorigen Abschnitt.

### Warum ein Skript allein nicht genügt

macOS vergibt Zugriffsrechte **pro Programm**, und was von `launchd` gestartet
wird, ist nicht dein Terminal. Der Zugriff, den du deinem Terminal erteilt
hast, gilt dort nicht. Typisches Bild:

```
touch: …/schreibtest: Operation not permitted
```

`Operation not permitted`, nicht `Permission denied` – das ist der Unterschied
zwischen „macOS verbietet es" und „die Dateirechte verbieten es". Auf dem
Server ist alles in Ordnung; blockiert wird auf dem Mac.

**Ein nacktes Skript kann diese Berechtigung nicht bekommen.**
Festplattenvollzugriff ist für App-Bundles gedacht. Man könnte `/bin/bash`
freigeben – dann hätte aber jedes Bash-Skript auf dem Rechner vollen Zugriff,
auch jedes, das man künftig aus Versehen ausführt. Deshalb die eigene Hülle:
Sie beschränkt die Berechtigung auf dieses eine Vorhaben.

### Die vier Fragen

Beim ersten geplanten Lauf fragt macOS der Reihe nach – **jede Frage genau
einmal**:

| Dialog | Wofür gebraucht |
|---|---|
| Zugriff auf Dateien auf einem **Netzwerkvolume** | auf die Freigabe schreiben |
| Zugriff auf die **Fotomediathek** | die Originale lesen |
| Nach Geräten im **lokalen Netzwerk** suchen | den Server überhaupt finden (ab macOS 15) |
| Zugriff auf **Daten anderer Apps** | Exportdatenbank in `Application Support` |

Alle vier bestätigen. Danach werden sie nicht wieder gestellt – die
Entscheidungen stehen dauerhaft in der Berechtigungsdatenbank von macOS.

> **Wichtig: das Bundle zuerst von Hand starten.**
>
> ```bash
> open ~/Applications/Fotobackup.app
> ```
>
> Ein LaunchAgent im Hintergrund bekommt diese Dialoge nämlich gar nicht
> gezeigt – macOS verweigert still. Der Lauf scheitert dann an einer Stelle,
> die nach etwas ganz anderem aussieht: Ohne die Berechtigung „Lokales
> Netzwerk" erreicht das Skript den Server nicht und meldet
>
> ```
> 192.168.0.x nicht erreichbar – vermutlich ausser Haus.
> ```
>
> obwohl der Server läuft und vom Terminal aus in Millisekunden antwortet. Wer
> das nicht weiss, sucht den Fehler im Netz statt in den Berechtigungen.
>
> Von Hand gestartet erscheinen die Dialoge normal. Erteilt sind sie danach
> für das Bundle – unabhängig davon, wer es künftig startet. Die geplanten
> Läufe im Hintergrund funktionieren also anschliessend.

> **Die Dialoge erscheinen unter dem Namen der App-Hülle**, also etwa
> „Fotobackup". Deshalb benennt `baue_bundle.sh` das Programm im Bundle um:
> Ohne das hiesse es „applet", und ein Dialog, in dem „applet" um Zugriff auf
> die Fotomediathek bittet, sieht aus wie etwas, das man wegklicken sollte.

### Wann die Fragen wiederkommen

- **Nach einem Neubau des Bundles.** `baue_bundle.sh` erzeugt es neu, dabei
  entsteht eine neue Signatur – für macOS ist das ein anderes Programm. Danach
  wieder einmal `open ~/Applications/Fotobackup.app`, sonst laufen die Dialoge
  ins Leere.
- **Nach manchen macOS-Aktualisierungen.** Es gab Fälle, in denen erteilte
  Berechtigungen für Hilfsprogramme reihenweise erloschen.
- Wenn das Bundle an einen anderen Ort verschoben wird.

Nicht dagegen bei gewöhnlichen Änderungen an `fotoexport.sh` – das Skript
liegt ausserhalb des Bundles und wird nur aufgerufen.

### Auslösen und nachsehen

```bash
launchctl kickstart -k gui/$(id -u)/local.fotobackup.export
```

Am besten tagsüber und mit Blick auf den Bildschirm, damit man die Dialoge
sieht. Ein Hintergrundprozess bringt sie nicht immer in den Vordergrund; falls
keiner erscheint, aber im Protokoll ein Fehler steht, lässt sich die
Berechtigung auch von Hand setzen:

> Systemeinstellungen → Datenschutz & Sicherheit → Festplattenvollzugriff bzw.
> Fotos → `+` → **⌘⇧G** → Pfad zum Bundle eingeben

> **Prüfe das Ergebnis, bevor du dich darauf verlässt.** Ein nächtlicher Lauf,
> der an einer Berechtigung scheitert, hinterlässt nichts als eine Zeile im
> Protokoll – und das Backup veraltet unbemerkt. Genau dafür gibt es die
> Überwachung weiter unten.

```bash
./mac/pruefe_umgebung.sh
```

---

## Start, Stopp, Kontrolle

| Zweck | Befehl |
|---|---|
| Laden (aktivieren) | `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.fotobackup.export.plist` |
| Entladen (deaktivieren) | `launchctl bootout gui/$(id -u)/local.fotobackup.export` |
| Sofort starten | `launchctl kickstart -k gui/$(id -u)/local.fotobackup.export` |
| Status und nächster Termin | `launchctl print gui/$(id -u)/local.fotobackup.export` |
| Läuft gerade etwas? | `pgrep -fl "osxphotos export"` |
| Laufenden Export abbrechen | `pkill -TERM -f "osxphotos export"` |

Nach jeder Änderung an der `.plist`: erst `bootout`, dann wieder `bootstrap`.
Ein blosses erneutes `bootstrap` lädt die Änderung nicht.

**Vorübergehend pausieren** – etwa vor einer längeren Reise:

```bash
launchctl bootout gui/$(id -u)/local.fotobackup.export
```

Die Datei bleibt liegen, der Job ist nur nicht geladen. `bootstrap` schaltet
ihn wieder ein.

---

## Automatik wieder entfernen

Drei Stufen, je nachdem wie weit zurück man will.

### Nur pausieren

Vor einer Reise, während einer Umstellung, oder wenn man eine Weile lieber von
Hand exportiert:

```bash
launchctl bootout gui/$(id -u)/local.fotobackup.export
```

Die Datei bleibt liegen, der Auftrag ist nur nicht geladen. Zurück mit
`bootstrap` (siehe Tabelle oben). Manuelle Läufe funktionieren unverändert
weiter – sie brauchen launchd nicht.

### Ganz entfernen

```bash
# 1. Auftrag entladen
launchctl bootout gui/$(id -u)/local.fotobackup.export

# 2. Auftragsdatei löschen
rm ~/Library/LaunchAgents/local.fotobackup.export.plist

# 3. App-Bundle löschen, falls eines angelegt wurde
rm -rf ~/Applications/Fotobackup.app

# 4. Kontrolle – darf nichts mehr finden
launchctl print gui/$(id -u)/local.fotobackup.export
```

**Nicht vergessen: die Berechtigung zurücknehmen.** Sie verschwindet nicht von
selbst, wenn das Programm gelöscht wird – der Eintrag bleibt in den
Systemeinstellungen stehen und gilt weiter, falls je wieder etwas unter
demselben Pfad auftaucht:

> Systemeinstellungen → Datenschutz & Sicherheit → Festplattenvollzugriff →
> Eintrag auswählen → `–`

Wurde stattdessen `/bin/bash` freigegeben, ist dieser Schritt umso wichtiger:
Sonst behält jedes Bash-Skript auf dem Rechner vollen Zugriff, lange nachdem
der Grund dafür weg ist.

**Was absichtlich bleibt** und beim Weiterarbeiten von Hand gebraucht wird:

| | |
|---|---|
| Exportdatenbank | das Gedächtnis, ohne das der nächste Lauf alles neu holt |
| Schlüsselbund-Eintrag | sonst kommt keine Verbindung mehr zustande |
| Protokolle unter `~/Library/Logs/fotoexport/` | Verlauf |
| `config` und die Skripte | für manuelle Läufe |

Der Merker des letzten geplanten Laufs (`letzter_lauf` neben der
Exportdatenbank) kann weg, stört aber nicht – ohne `--geplant` liest ihn
niemand.

### Auch die Überwachung zurückbauen

Nach dem Entfernen der Automatik **läuft die Überwachung weiter** – und das
ist meistens richtig so: Sie meldet dann, wenn du das manuelle Exportieren
vergisst. Genau dafür ist sie da.

Willst du sie trotzdem los, auf dem Server:

```bash
crontab -e        # Zeilen mit waechter.py und pruefe_bestand.py entfernen
```

Und das Gerät aus Home Assistant nehmen – dazu die Discovery-Nachricht mit
leerer Nutzlast überschreiben:

```bash
. ~/fotobackup/config
mosquitto_pub -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASS" \
  -t "homeassistant/device/$GERAET_ID/config" -r -n
```

Das Gerät verschwindet dann samt allen Entitäten. Die beiden Automationen
müssen von Hand gelöscht werden, sie hängen sonst an toten Entitäten.

Alternativ nur die Fristen entschärfen, statt alles abzubauen – in der `config`
auf dem Server:

```
EXPORT_WARNUNG_TAGE=90
EXPORT_FEHLER_TAGE=180
```

---

## Wenn der Mac geschlafen hat

**Ein zugeklappter Mac führt keine LaunchAgents aus.** Nach dem Aufklappen
holt `launchd` das Intervall nach – und dann greift wieder die Prüfung auf
Netzteil und Heimnetz. Passt es gerade nicht, wird es eine halbe Stunde später
erneut versucht, bis es passt.

Ein Export, der beim Zuklappen unterbrochen wird, ist unkritisch: Der nächste
Lauf setzt von selbst fort, ohne Zutun. Weil der Merker für den
Mindestabstand erst nach einem **erfolgreichen** Lauf gesetzt wird, versucht
es das Skript nach einem Abbruch bei nächster Gelegenheit erneut.

## Überwachung: wer merkt was

Die Aufgaben sind bewusst getrennt – und der Melder hängt nicht am überwachten
System.

| | Frage | Wo | Wann |
|---|---|---|---|
| **Überwachung** | Kommt noch etwas an? | Zielrechner, `pruefe_export.py` | täglich per cron |
| **Diagnose** | Warum kommt nichts? | Mac, `pruefe_umgebung.sh` | von Hand |

**Warum der Server überwacht und nicht der Mac:** Ein Melder, der am
überwachten System hängt, taugt nichts – fällt der Mac aus, meldet er auch
nicht mehr, dass er ausgefallen ist. Der Zielrechner merkt dagegen
zwangsläufig, wenn kein Bericht mehr eintrifft.

Gemessen wird das Alter des jüngsten Berichts **mit Fertigmarkierung**, also am
Ergebnis statt an der Absicht. Gemeldet wird zweistufig:

| Schwelle | Bedeutung |
|---|---|
| `EXPORT_WARNUNG_TAGE` (30) | Kann Abwesenheit sein – der Export braucht Netzteil und Heimnetz |
| `EXPORT_FEHLER_TAGE` (90) | Keine Abwesenheit mehr, sondern ein Defekt |

Grosszügig angesetzt, weil der Export an einem Laptop hängt, der auch mal
wochenlang nicht zu Hause ist. Häufige Fehlalarme gewöhnt man sich schneller
ab, als ein echter Ausfall auftritt.

**Die Meldung nennt keine Ursache** – das ist Absicht. Eine Push-Nachricht ist
der falsche Ort für Fehlersuche. Sie verweist stattdessen auf das Prüfskript.

### Und dann: die Ursache finden

`pruefe_umgebung.sh` liest `launchctl` und die Protokolle. Es prüft nicht, ob
*es selbst* schreiben kann – das ginge im Terminal ja – sondern **was beim
letzten geplanten Lauf passiert ist**:

```
Automatik
  ✓ LaunchAgent local.fotobackup.export ist geladen
  ✗ letzter geplanter Lauf endete mit Rückgabewert 1
      → touch: …/schreibtest_58537: Operation not permitted

    Das ist kein Rechteproblem auf dem Server, sondern macOS-Datenschutz.
    Ein Hintergrundprozess braucht eine eigene Erlaubnis für Netzwerk-
    volumes, und bekommt dafür keinen Dialog – er scheitert still.
    Typisch nach macOS-Aktualisierungen: die Berechtigung ist erloschen.

    Systemeinstellungen → Datenschutz & Sicherheit → Festplattenvollzugriff
```

Bekannte Fehlerbilder werden benannt statt nur weitergereicht. Der Text oben
ist keine Erfindung – genau so ist es bei der Einrichtung aufgetreten.

### Die Kehrseite: ausgelassene Läufe sind still

Wer seinen Laptop nie am Netzteil aufklappt, bei dem läuft der Export nie – und
niemand sagt es ihm. Deshalb prüft `pruefe_umgebung.sh` das Alter des jüngsten
vollständigen Exports:

```
✓ letzter vollständiger Export vor 0 Tag(en)
! letzter vollständiger Export vor 5 Tagen
✗ letzter vollständiger Export vor 14 Tagen
    → Läuft die Automatik? ./mac/fotoexport.sh von Hand starten
```

Gemessen wird am jüngsten Bericht mit Fertigmarkierung auf dem Server – also
am Ergebnis, nicht an der Absicht.

---

## Auf dem Server

Die Bestandsprüfung läuft per cron und meldet sich von selbst. Nachsehen muss
man nur, wenn etwas gemeldet wird.

```bash
crontab -l                                    # Zeitplan
tail -40 ~/fotobackup/protokolle/pruefung_*.log
~/fotobackup/pruefe_bestand.py                # von Hand anstossen
```

### Löschabgleich

Läuft bewusst **nicht** automatisch, weil das Verschieben eine Entscheidung
ist:

```bash
~/fotobackup/quarantaene.py                # nur anzeigen
~/fotobackup/quarantaene.py --verschieben  # nach Sichtung der Liste
```

Sinnvoll ist allerdings, die **Anzeige** einzuplanen – dann weiss Home
Assistant, wie viele Waisen es gibt, ohne dass jemand etwas verschiebt:

```
15 3 * * 1 /home/BENUTZER/fotobackup/quarantaene.py >> /home/BENUTZER/fotobackup/protokolle/cron.log 2>&1
```

Montags um 03:15, also nach dem nächtlichen Export vom Sonntag. Ohne
`--verschieben` wird nichts bewegt.

### Quarantäne leeren

Frühestens nach zwölf Monaten, und nur nach eigener Sichtung:

```bash
ls -R /srv/fotos/_geloescht/
```

Was dort liegt, ist in iCloud längst endgültig gelöscht. Es gibt keine zweite
Chance.

---

## Regelmässige Handgriffe

| Wann | Was |
|---|---|
| Wöchentlich | Export – von Hand oder per launchd |
| Monatlich | Bestandsprüfung – läuft von selbst |
| Nach jedem Export | Löschabgleich ansehen, wenn Waisen gemeldet werden |
| Jährlich | **Ein paar Bilder und ein Video tatsächlich öffnen** |
| Halbjährlich | `smartctl -a /dev/…` auf dem Server |
| Bei Bedarf | Quarantäne sichten und leeren |

Der jährliche Punkt ist der wichtigste und der, den man am ehesten vergisst.
Dateizahlen und Prüfsummen sagen, dass Dateien da und unversehrt sind – nicht,
dass sie das Richtige zeigen. **Ein Backup, das nie geöffnet wurde, ist eine
Vermutung.**
