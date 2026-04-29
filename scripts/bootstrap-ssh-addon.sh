#!/usr/bin/env bash
# Install, configure, and start the Advanced SSH & Web Terminal add-on
# (slug: a0d7b954_ssh) on a Home Assistant Green via the Supervisor REST API.
#
# Inputs (env):
#   HA_HOST, HA_TOKEN  see ha-api.sh
#   SSH_PUBKEY_FILE    path to your public key (default: ~/.ssh/id_ed25519.pub
#                      then ~/.ssh/id_rsa.pub)
#
# After this completes:
#   ssh root@<HA host without port> -p 22222

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ha-api.sh
source "${HERE}/ha-api.sh"

ADDON_SLUG="a0d7b954_ssh"

pubkey_file=""
if [[ -n "${SSH_PUBKEY_FILE:-}" ]]; then
  pubkey_file="${SSH_PUBKEY_FILE}"
elif [[ -f "${HOME}/.ssh/id_ed25519.pub" ]]; then
  pubkey_file="${HOME}/.ssh/id_ed25519.pub"
elif [[ -f "${HOME}/.ssh/id_rsa.pub" ]]; then
  pubkey_file="${HOME}/.ssh/id_rsa.pub"
else
  echo "No SSH public key found. Generate one with 'ssh-keygen -t ed25519' or set SSH_PUBKEY_FILE." >&2
  exit 1
fi

pubkey="$(< "${pubkey_file}")"
echo "Using public key: ${pubkey_file}"

ha_ping

addon_state() {
  ha_api GET "/api/hassio/addons/${ADDON_SLUG}/info" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("data",{}).get("state","not_installed"))'
}

state="$(addon_state || echo not_installed)"
if [[ "${state}" == "not_installed" ]]; then
  echo "Installing add-on ${ADDON_SLUG}..."
  ha_api POST "/api/hassio/addons/${ADDON_SLUG}/install" >/dev/null
fi

echo "Writing add-on options (authorized_keys + port 22222)..."
options_json=$(python3 - "${pubkey}" <<'PY'
import json, sys
pubkey = sys.argv[1].strip()
print(json.dumps({
    "options": {
        "authorized_keys": [pubkey],
        "password": "",
        "apks": [],
        "share_sessions": False
    },
    "network": {"22222/tcp": 22222},
}))
PY
)
ha_api POST "/api/hassio/addons/${ADDON_SLUG}/options" "${options_json}" >/dev/null

echo "Starting add-on..."
ha_api POST "/api/hassio/addons/${ADDON_SLUG}/start" >/dev/null || true

echo "Done. Test with:  ssh root@${HA_HOST%%:*} -p 22222"
