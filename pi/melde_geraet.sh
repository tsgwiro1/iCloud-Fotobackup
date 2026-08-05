#!/bin/bash
#
# melde_geraet.sh – meldet das Gerät per MQTT-Discovery bei Home Assistant an.
#
# Eine einzige Nachricht beschreibt alle Entitäten (device-based discovery,
# ab HA 2024.11). Dadurch erscheint in der MQTT-Integration ein Gerät mit allen
# Entitäten darunter, statt einem Dutzend loser Sensoren.
#
# Die Nachricht ist retained: Home Assistant findet das Gerät auch nach einem
# Neustart wieder, ohne dass dieses Skript erneut laufen muss.
#
# Erneut ausführen, wenn Entitäten dazukommen oder sich ändern.
# Zum Entfernen mit leerer Nutzlast auf dasselbe Topic publizieren:
#     mosquitto_pub ... -t homeassistant/device/<ID>/config -r -n

set -eu

HIER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for K in "$HIER/config" "$HIER/../config" "$HOME/fotobackup/config"; do
  if [ -f "$K" ]; then KONFIG="$K"; break; fi
done
if [ -z "${KONFIG:-}" ]; then
  echo "FEHLER: keine Konfigurationsdatei gefunden." >&2
  echo "Vorlage kopieren: cp config.example config" >&2
  exit 2
fi
# shellcheck source=/dev/null
. "$KONFIG"

if [ -z "${MQTT_HOST:-}" ]; then
  echo "Kein MQTT_HOST konfiguriert – nichts zu tun."
  exit 0
fi

PRAEFIX="${MQTT_PRAEFIX:-fotoexport}"
ID="${GERAET_ID:-fotoexport_nas}"
NAME="${GERAET_NAME:-Fotobackup NAS}"

TOPIC="homeassistant/device/${ID}/config"
STATE="${PRAEFIX}/pruefung/state"
WAISEN="${PRAEFIX}/waisen/state"
WAECHTER="${PRAEFIX}/waechter/state"

NUTZLAST=$(cat << EOF
{
  "dev": {
    "ids": "${ID}",
    "name": "${NAME}",
    "mf": "Eigenbau",
    "mdl": "osxphotos-Export mit BLAKE3-Bestandspruefung",
    "sw": "1.0"
  },
  "o": { "name": "fotobackup" },
  "cmps": {
    "pruefung_status": {
      "p": "sensor",
      "name": "Pruefung Status",
      "unique_id": "${ID}_pruefung_status",
      "state_topic": "$STATE",
      "value_template": "{{ value_json.status }}",
      "icon": "mdi:shield-check"
    },
    "pruefung_problem": {
      "p": "binary_sensor",
      "name": "Bestand beschaedigt",
      "unique_id": "${ID}_pruefung_problem",
      "device_class": "problem",
      "state_topic": "$STATE",
      "value_template": "{{ 'ON' if value_json.beanstandungen | int > 0 else 'OFF' }}",
      "json_attributes_topic": "$STATE",
      "json_attributes_template": "{{ {'defekte': value_json.defekte, 'fehlend': value_json.fehlend} | tojson }}"
    },
    "pruefung_geprueft": {
      "p": "sensor",
      "name": "Gepruefte Dateien",
      "unique_id": "${ID}_pruefung_geprueft",
      "state_topic": "$STATE",
      "value_template": "{{ value_json.geprueft }}",
      "unit_of_measurement": "Dateien",
      "state_class": "measurement",
      "icon": "mdi:file-multiple"
    },
    "pruefung_beanstandungen": {
      "p": "sensor",
      "name": "Beanstandungen",
      "unique_id": "${ID}_pruefung_beanstandungen",
      "state_topic": "$STATE",
      "value_template": "{{ value_json.beanstandungen }}",
      "unit_of_measurement": "Dateien",
      "state_class": "measurement",
      "icon": "mdi:file-alert"
    },
    "pruefung_zeitpunkt": {
      "p": "sensor",
      "name": "Letzte Pruefung",
      "unique_id": "${ID}_pruefung_zeitpunkt",
      "device_class": "timestamp",
      "state_topic": "$STATE",
      "value_template": "{{ value_json.zeitpunkt }}"
    },
    "pruefung_naechste": {
      "p": "sensor",
      "name": "Naechste Pruefung",
      "unique_id": "${ID}_pruefung_naechste",
      "device_class": "timestamp",
      "state_topic": "$STATE",
      "value_template": "{{ value_json.naechste_pruefung }}",
      "icon": "mdi:calendar-clock"
    },
    "pruefung_dauer": {
      "p": "sensor",
      "name": "Pruefdauer",
      "unique_id": "${ID}_pruefung_dauer",
      "device_class": "duration",
      "unit_of_measurement": "s",
      "state_topic": "$STATE",
      "value_template": "{{ value_json.dauer }}",
      "state_class": "measurement"
    },
    "pruefung_groesse": {
      "p": "sensor",
      "name": "Bestandsgroesse",
      "unique_id": "${ID}_pruefung_groesse",
      "device_class": "data_size",
      "unit_of_measurement": "GB",
      "state_topic": "$STATE",
      "value_template": "{{ value_json.groesse_gb }}",
      "state_class": "measurement"
    },
    "waisen_anzahl": {
      "p": "sensor",
      "name": "Verwaiste Dateien",
      "unique_id": "${ID}_waisen_anzahl",
      "state_topic": "$WAISEN",
      "value_template": "{{ value_json.waisen }}",
      "unit_of_measurement": "Dateien",
      "state_class": "measurement",
      "icon": "mdi:file-question",
      "json_attributes_topic": "$WAISEN",
      "json_attributes_template": "{{ {'liste': value_json.liste, 'bericht': value_json.bericht, 'verschoben': value_json.verschoben} | tojson }}"
    },
    "waisen_status": {
      "p": "sensor",
      "name": "Loeschabgleich Status",
      "unique_id": "${ID}_waisen_status",
      "state_topic": "$WAISEN",
      "value_template": "{{ value_json.status }}",
      "icon": "mdi:trash-can-outline"
    },
    "waisen_zeitpunkt": {
      "p": "sensor",
      "name": "Letzter Loeschabgleich",
      "unique_id": "${ID}_waisen_zeitpunkt",
      "device_class": "timestamp",
      "state_topic": "$WAISEN",
      "value_template": "{{ value_json.zeitpunkt }}"
    },
    "export_zeitpunkt": {
      "p": "sensor",
      "name": "Letzter Export",
      "unique_id": "${ID}_export_zeitpunkt",
      "device_class": "timestamp",
      "state_topic": "$WAECHTER",
      "value_template": "{{ value_json.export.letzter }}",
      "icon": "mdi:cloud-download"
    },
    "export_alter": {
      "p": "sensor",
      "name": "Export Alter",
      "unique_id": "${ID}_export_alter",
      "state_topic": "$WAECHTER",
      "value_template": "{{ value_json.export.alter_tage }}",
      "unit_of_measurement": "d",
      "state_class": "measurement",
      "icon": "mdi:calendar-alert"
    },
    "export_status": {
      "p": "sensor",
      "name": "Export Status",
      "unique_id": "${ID}_export_status",
      "state_topic": "$WAECHTER",
      "value_template": "{{ value_json.export.status }}",
      "json_attributes_topic": "$WAECHTER",
      "json_attributes_template": "{{ {'bericht': value_json.export.bericht, 'dateien': value_json.export.dateien, 'geprueft': value_json.geprueft} | tojson }}",
      "icon": "mdi:cloud-check"
    },
    "pruefung_termin_status": {
      "p": "sensor",
      "name": "Pruefung Termin Status",
      "unique_id": "${ID}_pruefung_termin_status",
      "state_topic": "$WAECHTER",
      "value_template": "{{ value_json.pruefung.status }}",
      "icon": "mdi:calendar-check"
    },
    "pruefung_alter": {
      "p": "sensor",
      "name": "Pruefung Alter",
      "unique_id": "${ID}_pruefung_alter",
      "state_topic": "$WAECHTER",
      "value_template": "{{ value_json.pruefung.alter_tage }}",
      "unit_of_measurement": "d",
      "state_class": "measurement",
      "icon": "mdi:calendar-alert"
    }
  }
}
EOF
)

ARGS=(-h "$MQTT_HOST" -p "${MQTT_PORT:-1883}")
[ -n "${MQTT_USER:-}" ] && ARGS+=(-u "$MQTT_USER" -P "${MQTT_PASS:-}")

mosquitto_pub "${ARGS[@]}" -t "$TOPIC" -r -m "$NUTZLAST"

echo "Gerät angemeldet: $TOPIC"