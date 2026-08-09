# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.2.1] - 2026-08-09

### Fixed
- Ein geplanter Lauf, der wegen des Mindestabstands ausgelassen wird, schliesst
  jetzt regulär ab, statt nach der Kopfzeile stumm auszusteigen.

  Vorher blieben Paare aus `=== Fotoexport … (geplant) ===` und
  `Konfiguration: …` ohne `Ende, Rückgabewert` im Protokoll stehen. Darauf
  meldete `pruefe_umgebung.sh` „letzter geplanter Lauf ohne Abschluss im
  Protokoll" – und weil auf einen Volllauf rund 40 Leerläufe folgen, stand
  diese Warnung fast immer.

  Der Abstand war der einzige der drei Abbruchgründe, der den EXIT-Trap
  abschaltete und selbst heraussprang; Netzteil und Server melden „verschoben"
  und lassen den Trap abschliessen. Der Zweig verhält sich jetzt wie seine
  Nachbarn und ist dabei kürzer geworden.

  ```
  15:11:19  Mindestabstand noch nicht erreicht (frei ab 10.08. 10:41) – Lauf ausgelassen.
  15:11:19  Ende, Rückgabewert 0.
  ```
- `pruefe_umgebung.sh` erkannte beim Grund für einen verschobenen Lauf nur
  „Kein Netzteil" und „nicht erreichbar" – der Mindestabstand fehlte und die
  Meldung endete mit einem Gedankenstrich ins Leere.
- Kommentar in `local.fotobackup.export.plist.example` berichtigt: Leerläufe
  enden nicht „ohne Logeintrag", sondern mit drei Zeilen.

## [1.2.0] - 2026-08-09

### Added
- `fotoexport.sh --status`: Zeile **Aufruf** im Block „NÄCHSTER geplanter Lauf" –
  wann launchd das nächste Mal nachfragt, wann er es zuletzt tat, und in welchem
  Abstand.

  Anlass war eine Fehldiagnose am 9. August 2026: Der Status meldete „Abstand
  frei" und alle Bedingungen grün, trotzdem lief nichts. Der geplante Aufruf um
  12:00:55 kam 33 Sekunden vor Ablauf der 20-Stunden-Sperre (12:01:28); der
  nächste stand erst um 12:31 an. Ohne diese Zeile liest sich „alles grün" als
  „startet gleich", obwohl bis zu 30 Minuten dazwischenliegen können.

  Das Intervall kommt aus `launchctl print`, nicht aus einer Konstante – wer
  `StartInterval` im Plist ändert, muss die Anzeige nicht nachziehen. Ist der
  Auftrag nicht geladen, sagt die Zeile das, statt einen Zeitpunkt zu erfinden.
  Der letzte Aufruf wird aus den `(geplant)`-Kopfzeilen im Tagesprotokoll
  gelesen; launchd gibt ihn nicht heraus.

  „ca." ist wörtlich gemeint: `StartInterval` zählt nur wache Zeit, nach einem
  Ruhezustand holt launchd den verpassten Aufruf beim Aufwachen nach. Der
  angezeigte Zeitpunkt ist eine Obergrenze, kein Termin.

### Changed
- `fotoexport.sh --status`: Der Block „NÄCHSTER geplanter Lauf" rechnet während
  eines aktiven Laufs voraus statt zurück.

  Vorher kündigte er mitten im Export einen Lauf „ca. 13:00" an und meldete
  „Abstand frei" – beides irreführend. Der Aufruf um 13:00 findet zwar statt,
  trifft aber auf die Sperrdatei und bricht sofort ab; und der Stempel für den
  Mindestabstand wird erst am Ende des laufenden Exports gesetzt.

  Jetzt: „Aufruf … – steigt an der Sperrdatei aus" und „Abstand frei ab ca.
  10.08. 08:50 (20 h nach Ende des laufenden Laufs)". Die Schätzung stammt aus
  der Restzeit der Fortschrittsanzeige; solange die fehlt (Vorbereitungsphase),
  wird keine Uhrzeit erfunden.

- Changelog-Einträge 1.0.0 und 1.0.1 zu einem Eintrag zusammengefasst. Beide
  Stände entstanden vor dem ersten Commit; für 1.0.0 gibt es keinen eigenen
  Stand im Repository, ein Tag darauf wäre nicht setzbar gewesen.

  Dabei sind sieben Einträge aus „Changed" nach „Added" gewandert, die neue
  Dateien oder Optionen beschrieben – `pruefe_umgebung.sh`, `docs/betrieb.md`,
  die LaunchAgent-Vorlage, `--geplant`. Sie standen unter „Changed", weil sie
  im Verlauf desselben Tages entstanden; als Änderung an einem Vorgänger
  lesen sie sich falsch.

### Fixed
- `fotoexport.sh --status`: Die Aufruf-Zeile rechnete ab dem *Start* des letzten
  Laufs und lag damit nach jedem langen Lauf um dessen Laufzeit daneben.

  `StartInterval` misst ab Prozess*ende*: Auf den Lauf vom 9. August 2026
  (12:30:56–12:51:41) folgte der nächste Aufruf nicht um 13:00:56, sondern um
  13:21:58. Bezugspunkt ist jetzt die Zeile `Ende, Rückgabewert` unterhalb der
  letzten `(geplant)`-Kopfzeile, bei einem laufenden Export dessen geschätztes
  Ende.
- Versions-Tags `v1.0.1` und `v1.1.0` nachgetragen. Der Changelog verwies seit
  der ersten Fassung auf `releases/tag/…`, gesetzt war nie einer – alle drei
  Links zeigten ins Leere.
- Linkliste: Verweis auf `v1.0.0` entfernt, `[Unreleased]` ergänzt.

## [1.1.0] - 2026-08-08

### Added
- `fotoexport.sh --status` – Auskunft ohne Nebenwirkungen. Zeigt, ob gerade ein
  Lauf aktiv ist und bei welchem Objekt von wie vielen er steht, wie der letzte
  vollständige Export ausging (verarbeitet, Laufzeit, Rückgabewert), und ob der
  nächste geplante Lauf überhaupt darf – Mindestabstand, Netzteil, Server,
  Platz.

  Der letzte Block ist der eigentliche Anlass: Ein geplanter Lauf steigt still
  aus, wenn eine dieser Bedingungen nicht stimmt, und den Grund sah man bisher
  erst hinterher im Protokoll.

  Schreibt nichts ins Protokoll, nimmt die Sperrdatei nicht und stört einen
  laufenden Export nicht. Mit `-w` aktualisiert sich die Anzeige alle
  60 Sekunden.

- `NETZTEIL_NOETIG` in der Konfiguration (Vorgabe `ja`). Bei `nein` läuft auch
  ein geplanter Export im Akkubetrieb.

  Zu bedenken: `caffeinate -s`, das den Ruhezustand des ganzen Systems
  verhindert, wirkt laut Apple nur am Netzteil. Im Akkubetrieb bleibt
  `caffeinate -i` gegen den Leerlauf-Ruhezustand – zugeklappt schläft der Mac
  trotzdem ein und der Lauf bricht ab.
- `mac/pruefe_dateien.py` – gezielte Einzelprüfung von Zeitstempeln. Zeigt
  Fotos-Datum, Importdatum und das Datum aus der Datei nebeneinander und macht
  damit unterscheidbar, ob ein verdächtiges Datum echt oder ein Importartefakt
  ist.

### Removed
- `mac/fotostatus.sh` – geht in `fotoexport.sh --status` auf. Zwei Werkzeuge
  für dieselbe Frage waren einmal zu viel.

  Übernommen wurden Dateizahl und Grösse am Ziel (weiterhin per SSH gezählt,
  nicht über den SMB-Mount), die Grösse der Exportdatenbank und der
  Wiederholmodus. Ersetzt wurde die Fortschrittsanzeige: `fotostatus.sh` mass
  sie an der Zahl der Dateien am Ziel. Das funktioniert beim Erstlauf, ist im
  Alltag aber blind – ein inkrementeller Lauf exportiert nichts, also bewegt
  sich diese Zahl nicht. `--status` liest stattdessen den Objektzähler von
  osxphotos aus dem Protokoll.

### Changed
- **`ProcessType` in der launchd-Vorlage von `Background` auf `Standard`.**
  Das ist der Unterschied zwischen 20 und 66 Minuten.

  `Background` klingt nach der richtigen Wahl für einen nächtlichen
  Wartungslauf, weist launchd aber an, die I/O des Jobs aktiv zu drosseln.
  Dieser Lauf besteht praktisch nur aus I/O – er fragt jede Dateisignatur
  einzeln über SMB ab.

  Gemessen an ~50'000 Dateien, gleiche Arbeit, gleiches Ergebnis:
  `Background` 751 Objekte/min (64–73 min), `Standard` 2626 Objekte/min
  (20 min). `Nice 5` bleibt; es wirkt auf die CPU, die hier nicht das
  Nadelöhr ist.

### Fixed
- `docs/betrieb.md` verwies auf einen Arbeitsordner neben dem Repository.

### Notes
- **Ein Berechtigungsdialog beim geplanten Lauf heisst nicht, dass die
  Berechtigung fehlt – er kann auch bedeuten, dass sie auf einen alten Pfad
  zeigt.** Nach dem Umbenennen des Programms im Bundle (`applet` →
  Bundle-Name) blieb der Eintrag für Festplattenvollzugriff auf
  `Contents/MacOS/applet` stehen. Die Systemeinstellungen zeigten den Schalter
  weiter als eingeschaltet, zur Laufzeit meldete tccd
  `SystemPolicyAllFiles → Denied (Service Policy)`, und macOS wich auf die
  granulare Abfrage „Daten anderer Apps" aus – bei jedem Lauf neu.

  Weder `−` in den Systemeinstellungen noch `tccutil reset` halfen;
  ohne `sudo` trifft `tccutil` ausserdem nur die Benutzerdatenbank, während
  Festplattenvollzugriff in der Systemdatenbank steht. Was half: **Schalter
  aus, kurz warten, wieder an.** Damit schreibt macOS die Zeile neu.

  Merke: Die Liste in den Systemeinstellungen ist eine Anzeige, kein Zustand.
  Was gilt, steht im Log:
  `log show --last 1h --predicate 'process == "tccd"' | grep -i fotobackup`
- Eine fehlende Berechtigung **Lokales Netzwerk** sieht im Protokoll aus wie
  Abwesenheit: Das Skript meldet „nicht erreichbar – vermutlich ausser Haus",
  weil es die stille Verweigerung nicht von einem toten Server unterscheiden
  kann. Ein LaunchAgent im Hintergrund bekommt den Dialog nie zu sehen. Nach
  jedem Neubau des Bundles deshalb **einmal von Hand starten**
  (`open ~/Applications/Fotobackup.app`), danach übernimmt die Automatik.

## [1.0.1] - 2026-08-05

Erste Fassung, entstanden am 3. und 4. August. Im Einsatz mit rund 48'800
Objekten und 167 GB.

Die Zwischenstände 1.0.0 und 1.0.1 lagen beide vor dem ersten Commit und sind
hier zu einem Eintrag zusammengefasst.

### Added
- `mac/fotoexport.sh` – Export der Fotomediathek über osxphotos auf eine
  SMB-Freigabe. Baut die Verbindung selbst auf und trennt sie am Ende wieder,
  auch bei Abbruch oder Fehler (`trap … EXIT INT TERM`).
- Platzwächter im Export: prüft vor dem Start und danach jede Minute den freien
  Platz auf der lokalen Platte und beendet den Lauf sauber, bevor sie volläuft.
- Fertigmarkierung `<bericht>.csv.fertig` nach vollständigem Export – Grundlage
  dafür, dass der Löschabgleich einem Bericht überhaupt trauen darf.
- `mac/fotostatus.sh` – Fortschritt eines laufenden Exports, zählt per SSH
  direkt auf dem Server statt über SMB.
- `mac/platztest.sh` – misst, ab wann macOS den als „löschbar" geführten
  Speicher der Fotomediathek tatsächlich freigibt.
- `pi/pruefe_bestand.py` – monatliche BLAKE3-Prüfung des Bestands gegen
  Bitfäule. Unterscheidet über Größe und Änderungszeit zwischen legitimem
  Neuexport und stillem Datenverfall.
- `pi/quarantaene.py` – Löschabgleich gegen den Exportbericht. Verschiebt
  Verwaistes nach `_geloescht/JJJJ-MM/` statt es zu löschen.
- Drei Sperren im Löschabgleich: Fertigmarkierung, Altersgrenze des Berichts
  (14 Tage), Plausibilitätsgrenze (2 % des Bestands).
- `pi/melde_geraet.sh` – MQTT-Discovery für Home Assistant. Eine einzige
  Nachricht legt ein Gerät mit elf Entitäten an (device-based discovery).
- `pi/konfig.py` – gemeinsamer Konfigurationsleser für Bash und Python.
- `config.example` – alle rechnerspezifischen Werte an einem Ort.
- Dokumentation: Installationsanleitung mit Kontrollen je Schritt,
  Entscheidungsdokument mit Messwerten, Home-Assistant-Anleitung mit fertigen
  Automationen.
- `mac/baue_bundle.sh` – erzeugt eine App-Hülle für den geplanten Export.

  Nötig, weil macOS Zugriffsrechte pro Programm vergibt und ein Skript unter
  `launchd` still an `Operation not permitted` scheitert. Festplattenvollzugriff
  lässt sich einer nackten ausführbaren Datei nicht zuverlässig erteilen – die
  Berechtigung ist für App-Bundles gedacht. Die Alternative, `/bin/bash`
  freizugeben, würde jedem Bash-Skript auf dem Rechner vollen Zugriff geben.

  Das Programm im Bundle wird von `applet` auf den Bundle-Namen umbenannt und
  neu signiert: Unter diesem Namen fragt macOS später nach Berechtigungen, und
  ein Dialog von „applet" sieht aus wie etwas, das man wegklicken sollte.

  Die Hülle schluckt Fehler bewusst – ein Applet zeigt sonst einen Dialog, und
  ein nächtlicher Lauf, der auf einen Klick wartet, hängt für immer. Deshalb
  liest die Diagnose das Protokoll statt den launchd-Rückgabewert.
- Abschnitt „Die vier Fragen" in der Betriebsanleitung: welche Berechtigungen
  beim ersten geplanten Lauf abgefragt werden, wofür sie gebraucht werden, und
  wann sie wiederkommen.
- `pi/waechter.py` – Überwachung beider regelmässiger Aufgaben, täglich per
  cron auf dem Zielrechner. Misst das Alter des jüngsten Exportberichts mit
  Fertigmarkierung und das der Prüfsummenliste. Fristen: `EXPORT_WARNUNG_TAGE`
  (30), `EXPORT_FEHLER_TAGE` (90), `PRUEFUNG_UEBERFAELLIG_TAGE` (35).

  Bewusst auf dem Zielrechner und nicht auf dem Mac: Ein Melder, der am
  überwachten System hängt, taugt nichts – fällt der Mac aus, meldet er auch
  nicht mehr, dass er ausgefallen ist.
- Fünf Entitäten dazu und eine gemeinsame Automation „etwas läuft nicht mehr"
  mit einem Zweig je Fall.
- Abschnitt „Automatik wieder entfernen" in der Betriebsanleitung: pausieren,
  ganz entfernen, Überwachung zurückbauen. Mit dem Hinweis, dass die erteilte
  Berechtigung nicht von selbst verschwindet, wenn das Programm gelöscht wird –
  gerade bei einer Freigabe von `/bin/bash` bleibt sonst dauerhaft mehr offen
  als nötig.
- `mac/pruefe_umgebung.sh` – Diagnose beider Seiten: Werkzeuge, Erreichbarkeit,
  Schlüsselbund, Platz, Serverzustand, Berichte, Zeitpläne. Nennt zu jedem
  fehlenden Punkt den nötigen Befehl und den passenden Schritt der Anleitung.

  Bewusst ein **Prüf-** und kein Installationsskript: Die heiklen Schritte –
  Finder-Connect mit Schlüsselbund, Fotos-Berechtigung, `smbpasswd` – sind
  GUI-gebunden und nicht skriptbar. Und ein Eingriff in eine fremde
  `smb.conf` kann bestehende Freigaben zerlegen. Ein Skript, das nur liest,
  kann nichts kaputtmachen und altert kaum.

  Erkennt einen laufenden Export und ordnet die dadurch auffälligen Punkte
  (belegter Mountpoint, Bericht ohne Markierung, offenes Protokoll) korrekt
  ein, statt sie zu bemängeln. Ebenso wird knapper Plattenplatz nur bemängelt,
  solange der Erstlauf noch aussteht – danach brauchen Folgeläufe kaum Platz.
- Fehlerdiagnose in `pruefe_umgebung.sh`: Statt zu prüfen, ob *es selbst*
  schreiben kann, liest es `launchctl` und die Protokolle aus und beantwortet,
  **was beim letzten geplanten Lauf passiert ist**. Bekannte Fehlerbilder
  werden benannt statt weitergereicht – etwa `Operation not permitted` als
  fehlende Netzwerkvolume-Berechtigung nach einer macOS-Aktualisierung.

  Damit ist die Arbeitsteilung klar: Der Server meldet **dass** etwas klemmt,
  das Prüfskript sagt **was**. Eine Push-Nachricht ist der falsche Ort für
  Fehlersuche.
- Alterprüfung des letzten vollständigen Exports in `pruefe_umgebung.sh`.
  Gegenstück zu den ausgelassenen Läufen: Wer den Laptop nie am Netzteil
  aufklappt, bei dem läuft der Export nie – und niemand sagt es ihm. Gemessen
  wird am jüngsten Bericht mit Fertigmarkierung, also am Ergebnis statt an der
  Absicht.
- `--geplant` in `mac/fotoexport.sh` – für den Betrieb unter `launchd`. Läuft
  nur am Netzteil und im erreichbaren Heimnetz; sonst wird der Lauf still
  ausgelassen, mit **Rückgabewert 0** statt Fehler. Ein Export im Akkubetrieb
  kostet Ladung und hält den Rechner wach; ausser Haus ist der Server ohnehin
  nicht erreichbar. Beides ist kein Defekt und soll keinen Alarm auslösen.
  Manuelle Aufrufe kennen diese Sperren nicht.
- `docs/betrieb.md` – Betriebsanleitung: manuelle Ausführung, Einrichtung des
  wöchentlichen Laufs per `launchd`, Start/Stopp/Kontrolle, Verhalten nach
  Ruhezustand, regelmässige Handgriffe.
- `mac/local.fotobackup.export.plist.example` – Vorlage für den LaunchAgent.
  Bewusst ein Agent im Benutzerkontext, kein Daemon: Der Export braucht
  Schlüsselbund und Fotos-Berechtigung des angemeldeten Benutzers.
- Abschnitt zur Berechtigungshürde unter `launchd`: Der Zugriff auf die
  Fotos-Mediathek gilt pro aufrufendem Programm, `/bin/bash` unter launchd
  braucht eine eigene Freigabe.
- Hinweis in der Installationsanleitung: Die Fotos-Berechtigung gilt pro
  aufrufender Anwendung. Wer osxphotos aus einer anderen Umgebung startet als
  der, die er freigegeben hat, bekommt `could not get authorization to access
  Photos library`.

### Changed
- Die beiden Überfälligkeits-Automationen zu einer zusammengelegt. Sie
  beantworteten dieselbe Frage in zwei Bauarten; die Fristen lagen zudem an
  zwei Orten – eine davon als Sekundenzahl in einem Jinja-Template mitten in
  einer HA-Automation. Jetzt stehen alle drei Fristen in `config` auf dem
  Server, der Wächter bewertet sie, und HA reagiert nur noch auf einen
  Statuswechsel. Damit entfällt auch das letzte Template in Logikposition.

  Es bleiben zwei Automationen, getrennt nach Art des Problems: **Schaden**
  (Bitfäule gefunden) und **Stillstand** (etwas läuft nicht mehr).

### Fixed
- Probeläufe (`--album`, `--dry-run`) schreiben ihren Bericht jetzt als
  `probe_JJJJ-MM-TT.csv`. Vorher überschrieb ein Testlauf den Bericht eines
  Vollexports vom selben Tag – und damit die Grundlage des Löschabgleichs.
- Probeläufe entfernen die Fertigmarkierung eines früheren Vollexports nicht
  mehr.
- `quarantaene.py` sucht den jüngsten Bericht **mit** Fertigmarkierung, statt
  am jüngsten Bericht überhaupt zu scheitern. Ein Testlauf blockiert den
  Löschabgleich damit nicht mehr bis zum nächsten Vollexport.

### Notes
Erkenntnisse aus der Inbetriebnahme, die in die Voreinstellungen eingeflossen
sind:

- Die Untergrenze des Platzwächters steht auf **8 GB**, nicht höher. macOS gibt
  den „löschbaren" Speicher der Fotomediathek erst bei rund 5 GB frei – eine
  höhere Grenze bricht den Export ab, bevor das System aufräumen kann.
- Die Exportdatenbank liegt **lokal**, nicht auf der Freigabe. Sonst weicht
  osxphotos auf eine RAM-Kopie aus und verwirft bei einem Abbruch den gesamten
  Fortschritt.
- `osxphotos --cleanup` wird **nicht** verwendet: Es löscht alles im Zielordner,
  was nicht zum Lauf gehört – auch Berichte und Quarantäne.
- `mount_smbfs -N` bedeutet „frag nicht nach", nicht „nimm das gespeicherte
  Passwort". Das Passwort wird ausdrücklich aus dem Schlüsselbund geholt.
- Samba braucht `force create mode`, nicht nur `create mask`: Eine Maske
  erlaubt Bits, sie erzwingt sie nicht.

[Unreleased]: https://github.com/tsgwiro1/iCloud-Fotobackup/compare/v1.2.1...HEAD
[1.2.1]: https://github.com/tsgwiro1/iCloud-Fotobackup/releases/tag/v1.2.1
[1.2.0]: https://github.com/tsgwiro1/iCloud-Fotobackup/releases/tag/v1.2.0
[1.1.0]: https://github.com/tsgwiro1/iCloud-Fotobackup/releases/tag/v1.1.0
[1.0.1]: https://github.com/tsgwiro1/iCloud-Fotobackup/releases/tag/v1.0.1
