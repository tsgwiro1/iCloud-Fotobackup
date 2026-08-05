# Home Assistant

Die Anbindung ist optional. Ohne `MQTT_HOST` in der Konfiguration laufen alle
Skripte unverändert, nur eben stumm.

---

## Das Gerät

`melde_geraet.sh` sendet **eine einzige** Discovery-Nachricht, die alle
Entitäten beschreibt (device-based discovery, ab HA 2024.11). Dadurch erscheint
in der MQTT-Integration ein Gerät mit allen Entitäten darunter, statt einem
Dutzend loser Sensoren.

Die Nachricht ist retained – Home Assistant findet das Gerät nach einem
Neustart wieder, ohne dass das Skript erneut laufen muss.

```
homeassistant/device/<GERAET_ID>/config     einmalig, retained
<MQTT_PRAEFIX>/pruefung/state               nach jedem Prüflauf
<MQTT_PRAEFIX>/waisen/state                 nach jedem Löschabgleich
<MQTT_PRAEFIX>/waechter/state               täglich, Termine beider Aufgaben
```

Das Discovery-Topic **muss** unter `homeassistant/` liegen, das ist in HA fest
verdrahtet. Frei wählbar sind nur die Daten-Topics.

## Entitäten

| Entität | Typ | Bedeutung |
|---|---|---|
| Pruefung Status | Sensor | `ok` oder `beanstandet` |
| Bestand beschaedigt | Binärsensor `problem` | Auslöser für die Meldung |
| Gepruefte Dateien | Sensor | Umfang des letzten Laufs |
| Beanstandungen | Sensor | Zahl beschädigter Dateien |
| Letzte Pruefung | Sensor `timestamp` | wann zuletzt geprüft wurde |
| Naechste Pruefung | Sensor `timestamp` | wann der nächste Lauf fällig ist |
| Pruefdauer | Sensor `duration` | Laufzeit in Sekunden |
| Bestandsgroesse | Sensor `data_size` | Gesamtgrösse in GB |
| Verwaiste Dateien | Sensor | Ergebnis des Löschabgleichs |
| Loeschabgleich Status | Sensor | `ok`, `waisen` oder `unplausibel` |
| Letzter Loeschabgleich | Sensor `timestamp` | wann zuletzt abgeglichen wurde |
| Letzter Export | Sensor `timestamp` | wann zuletzt vom Mac exportiert wurde |
| Export Alter | Sensor, Tage | Alter des jüngsten vollständigen Exports |
| Export Status | Sensor | `ok`, `ueberfaellig`, `versaeumt` |
| Pruefung Termin Status | Sensor | `ok` oder `ueberfaellig` |
| Pruefung Alter | Sensor, Tage | Alter der Prüfsummenliste |

Die Liste der betroffenen Dateien hängt als Attribut am jeweiligen Zähler.

> **Achtung bei Änderungen:** `GERAET_ID` geht in jede `unique_id` ein. Wird sie
> nachträglich geändert, legt HA alle Entitäten neu an – die alten bleiben als
> Karteileichen zurück und die neuen bekommen ein `_2` angehängt. Vorher die
> alte Registrierung entfernen:
>
> ```bash
> mosquitto_pub -h HOST -u USER -P PASS \
>   -t homeassistant/device/ALTE_ID/config -r -n
> ```

---

## Automation 1: Bestand beschädigt

Meldet sich, wenn die Prüfung eine Datei findet, deren Inhalt sich geändert hat,
ohne dass Grösse oder Zeitstempel es täten – also stiller Datenverfall.

```yaml
alias: Fotobackup - Bestand beschaedigt
mode: single
triggers:
  - trigger: state
    entity_id: binary_sensor.DEIN_GERAET_bestand_beschaedigt
    to: "on"
actions:
  - action: persistent_notification.create
    data:
      notification_id: fotobackup_beschaedigt
      title: "Fotobackup: beschädigte Dateien"
      message: >
        Die Bestandsprüfung hat
        {{ states('sensor.DEIN_GERAET_beanstandungen') }}
        beschädigte Datei(en) gefunden.

        **Betroffen:**
        {% for d in state_attr('binary_sensor.DEIN_GERAET_bestand_beschaedigt', 'defekte') %}
        - `{{ d }}`
        {% endfor %}

        Diese Dateien haben unveränderte Größe und Änderungszeit, aber einen
        anderen Inhalt als beim letzten Lauf.

        **Behebung:** Die Dateien auf dem Server löschen und den Export laufen
        lassen – er holt sie aus iCloud neu.
```

## Automation 2: Etwas läuft nicht mehr

Der Totmannschalter für beide Aufgaben. Nicht der gefundene Fehler ist
gefährlich, sondern der Auftrag, der stillschweigend nicht mehr läuft – dann
sieht Stille aus wie Erfolg.

Ein Zweig je Fall, unterschieden über Trigger-IDs:

```yaml
alias: Fotobackup - etwas laeuft nicht mehr
mode: single
triggers:
  - trigger: state
    entity_id: sensor.DEIN_GERAET_export_status
    to: "ueberfaellig"
    id: export_warnung
  - trigger: state
    entity_id: sensor.DEIN_GERAET_export_status
    to: "versaeumt"
    id: export_fehler
  - trigger: state
    entity_id: sensor.DEIN_GERAET_pruefung_termin_status
    to: "ueberfaellig"
    id: pruefung
actions:
  - choose:
      - conditions:
          - condition: trigger
            id: export_warnung
        sequence:
          - action: persistent_notification.create
            data:
              notification_id: fotobackup_export_alt
              title: "Fotobackup: lange kein Export"
              message: >
                Der letzte vollständige Export liegt
                {{ states('sensor.DEIN_GERAET_export_alter') }} Tage zurück.

                Warst du länger nicht zu Hause, ist das erwartbar – der Export
                braucht Netzteil und Heimnetz.

                **Ursache finden:** Auf dem Mac `./mac/pruefe_umgebung.sh`.
      - conditions:
          - condition: trigger
            id: export_fehler
        sequence:
          - action: persistent_notification.create
            data:
              notification_id: fotobackup_export_versaeumt
              title: "Fotobackup: seit Monaten kein Export"
              message: >
                Das ist keine Abwesenheit mehr, sondern ein Defekt. Alles seither
                Fotografierte liegt nur in iCloud – ohne zweite Kopie.
      - conditions:
          - condition: trigger
            id: pruefung
        sequence:
          - action: persistent_notification.create
            data:
              notification_id: fotobackup_pruefung_ueberfaellig
              title: "Fotobackup: Bestandsprüfung läuft nicht mehr"
              message: >
                Das heißt nicht, dass Dateien beschädigt sind. Es heißt, dass
                niemand mehr nachsieht.
```

### Warum die Fristen nicht hier stehen

Eine frühere Fassung verglich Zeitstempel direkt in HA, mit `86400` als
Sekundenzahl in einem Jinja-Template. Das funktionierte, hatte aber zwei
Nachteile: Die Frist lag dort, wo sie niemand vermutet, und der
Best-Practice-Prüfer warnte zu Recht vor einem Template in Logikposition.

Jetzt bewertet der Wächter auf dem Server die Fristen – sie stehen als
verständliche Zahlen in `config` – und meldet nur noch einen Status. HA
reagiert auf einen Statuswechsel, mehr nicht. **Logik gehört dorthin, wo die
Daten sind.**

---

## Warum Notifications und keine Push-Meldungen

Eine Push-Meldung ist einen Moment lang da und dann weg. Eine Notification
bleibt stehen, bis sie quittiert wird. Für etwas, das ein- bis zweimal im Jahr
auftritt und dann wirklich bemerkt werden muss, ist das die robustere Wahl.

Wer Push bevorzugt, ersetzt `persistent_notification.create` durch
`notify.mobile_app_…` – beides gleichzeitig geht natürlich auch.

## Kein „Last Will"

Ursprünglich vorgesehen, dann verworfen: Ein LWT hängt an einer bestehenden
MQTT-Verbindung. Hier publiziert ein kurzlebiger Prozess einmal im Monat, es
gibt keine dauerhafte Verbindung, an der ein LWT hängen könnte. Die Rolle
übernimmt der Zeitstempel „Naechste Pruefung" plus die zweite Automation.
