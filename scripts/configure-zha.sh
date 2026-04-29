#!/usr/bin/env bash
# Create the ZHA config entry against the Zigbee adapter, with no UI clicks.
# Walks the config-flow REST API the same way the frontend does.
#
# Inputs (env):
#   HA_HOST, HA_TOKEN  see ha-api.sh
#   ZHA_DEVICE_PATH    optional: full /dev/serial/by-id/... path. If unset,
#                      the script auto-discovers a Nabu Casa / Home Assistant
#                      Connect adapter (ZBT-1, ZBT-2, SkyConnect) from
#                      /api/hassio/hardware/info.
#   ZHA_RADIO_TYPE     optional override: ezsp | znp | deconz | zigate | xbee
#                      Default: auto-pick based on the matched adapter.
#   ZHA_BAUDRATE       default 115200
#   ZHA_FLOW_CONTROL   default software

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ha-api.sh
source "${HERE}/ha-api.sh"

ZHA_BAUDRATE="${ZHA_BAUDRATE:-115200}"
ZHA_FLOW_CONTROL="${ZHA_FLOW_CONTROL:-software}"

ha_ping

# --- 1. Resolve device path + radio type --------------------------------------
device_path="${ZHA_DEVICE_PATH:-}"
radio_type="${ZHA_RADIO_TYPE:-}"

if [[ -z "${device_path}" || -z "${radio_type}" ]]; then
  echo "Auto-discovering Zigbee adapter via Supervisor hardware info..."
  hw_json="$(ha_api GET /api/hassio/hardware/info)"
  read -r auto_path auto_radio <<<"$(python3 - "$hw_json" <<'PY'
import json, sys
data = json.loads(sys.argv[1]).get("data", {})
devices = data.get("devices", [])
priority = [
    # (substring to match in by-id, radio_type)
    ("Home_Assistant_Connect_ZBT-2", "znp"),
    ("Home_Assistant_Connect_ZBT-1", "ezsp"),
    ("SkyConnect",                   "ezsp"),
    ("Sonoff_Zigbee_3.0_USB_Dongle", "ezsp"),
    ("ConBee",                       "deconz"),
    ("CC2652",                       "znp"),
    ("CC2531",                       "znp"),
]
match_path, match_radio = "", ""
for d in devices:
    by_id = next((l for l in d.get("by_id", []) or [] if l), "") or d.get("dev_path", "")
    for needle, radio in priority:
        if needle.lower() in by_id.lower():
            match_path, match_radio = by_id, radio
            break
    if match_path:
        break
print(f"{match_path} {match_radio}")
PY
)"
  device_path="${device_path:-$auto_path}"
  radio_type="${radio_type:-$auto_radio}"
fi

if [[ -z "${device_path}" ]]; then
  echo "Could not find a Zigbee adapter. Set ZHA_DEVICE_PATH explicitly." >&2
  exit 1
fi
if [[ -z "${radio_type}" ]]; then
  echo "Could not infer radio_type. Set ZHA_RADIO_TYPE (ezsp, znp, deconz, ...)." >&2
  exit 1
fi

echo "Adapter:    ${device_path}"
echo "Radio type: ${radio_type}"

# --- 2. Start the ZHA config flow --------------------------------------------
echo "Starting ZHA config flow..."
flow_start='{"handler":"zha","show_advanced_options":true}'
flow_resp="$(ha_api POST /api/config/config_entries/flow "${flow_start}")"
flow_id="$(echo "${flow_resp}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["flow_id"])')"
echo "flow_id=${flow_id}"

# --- 3. Pick "manual" path so we can specify radio_type/device_path directly --
# The flow first asks the user to pick a discovered radio. We send the choice
# "manual" so we can supply device_path and radio_type ourselves.
manual_payload="$(python3 -c 'import json; print(json.dumps({"next_step_id":"manual_pick_radio_type"}))')"
ha_api POST "/api/config/config_entries/flow/${flow_id}" "${manual_payload}" >/dev/null || true

radio_payload="$(python3 -c 'import json,sys; print(json.dumps({"radio_type": sys.argv[1]}))' "${radio_type}")"
ha_api POST "/api/config/config_entries/flow/${flow_id}" "${radio_payload}" >/dev/null

port_payload="$(python3 -c '
import json, sys
print(json.dumps({
  "device": {
    "path": sys.argv[1],
    "baudrate": int(sys.argv[2]),
    "flow_control": sys.argv[3],
  }
}))
' "${device_path}" "${ZHA_BAUDRATE}" "${ZHA_FLOW_CONTROL}")"
echo "Submitting device path..."
ha_api POST "/api/config/config_entries/flow/${flow_id}" "${port_payload}" >/dev/null

# --- 4. Confirm a fresh network (default) -------------------------------------
form_payload="$(python3 -c 'import json; print(json.dumps({"next_step_id":"form_new_network"}))')"
ha_api POST "/api/config/config_entries/flow/${flow_id}" "${form_payload}" >/dev/null || true

echo
echo "ZHA config flow submitted. Verifying entry state..."
ha_api GET /api/config/config_entries/entry \
  | python3 -c 'import json,sys; [print(e["entry_id"], e["state"]) for e in json.load(sys.stdin) if e["domain"]=="zha"]'

cat <<'EOM'

Next steps:
  - Pair a device:  curl -fsSL -X POST \
        -H "Authorization: Bearer $HA_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"duration":60}' \
        "http://$HA_HOST/api/services/zha/permit"
  - Remove a device: zha.remove service with {"ieee": "xx:xx:..."}.
EOM
