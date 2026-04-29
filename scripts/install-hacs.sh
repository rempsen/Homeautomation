#!/usr/bin/env bash
# Install HACS on the HA Green and register the integration via the
# config-flow REST API. Requires SSH access (via the Advanced SSH add-on
# bootstrapped by bootstrap-ssh-addon.sh).
#
# Inputs (env):
#   HA_HOST, HA_TOKEN  see ha-api.sh
#   HA_SSH_HOST        host to ssh into (default: HA_HOST without :port)
#   HA_SSH_PORT        default 22222 (the SSH add-on)
#   HA_SSH_USER        default root

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ha-api.sh
source "${HERE}/ha-api.sh"

HA_SSH_HOST="${HA_SSH_HOST:-${HA_HOST%%:*}}"
HA_SSH_PORT="${HA_SSH_PORT:-22222}"
HA_SSH_USER="${HA_SSH_USER:-root}"

ha_ping

echo "Running HACS installer over SSH on ${HA_SSH_USER}@${HA_SSH_HOST}:${HA_SSH_PORT}..."
ssh -o StrictHostKeyChecking=accept-new \
    -p "${HA_SSH_PORT}" "${HA_SSH_USER}@${HA_SSH_HOST}" \
    'wget -O - https://get.hacs.xyz | bash -'

echo "Restarting Home Assistant Core to pick up the new custom_component..."
ha_api POST /api/services/homeassistant/restart >/dev/null || true

echo "Waiting for Core to come back..."
for _ in $(seq 1 60); do
  if ha_api GET /api/ >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

echo "Starting HACS config flow..."
flow_resp="$(ha_api POST /api/config/config_entries/flow '{"handler":"hacs"}')"
flow_id="$(echo "${flow_resp}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["flow_id"])')"

# HACS first step asks the user to acknowledge each ToS-style checkbox.
ack='{"acc_logs":true,"acc_addons":true,"acc_untested":true,"acc_disable":true}'
ha_api POST "/api/config/config_entries/flow/${flow_id}" "${ack}" >/dev/null

cat <<'EOM'

HACS installed and registered.
Next steps:
  1. Open the HACS device-flow link in your browser when prompted by the
     HACS notification in HA. (One-time GitHub OAuth, unavoidable.)
  2. Edit hacs.yaml in this repo to declare which integrations/plugins to
     track, then run scripts/hacs-sync.sh.
EOM
