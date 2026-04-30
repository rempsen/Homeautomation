#!/usr/bin/env bash
# Install, configure, and start the Advanced SSH & Web Terminal add-on
# (slug: a0d7b954_ssh) on a Home Assistant Green via the Supervisor API.
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

addon_version() {
  ha_supervisor get "/addons/${ADDON_SLUG}/info" \
    | python3 -c 'import json, sys; print(json.loads(sys.stdin.read() or "{}").get("version") or "")'
}

ver="$(addon_version)"
if [[ -z "$ver" ]]; then
  echo "Installing add-on ${ADDON_SLUG} (this can take 30-90s)..."
  ha_supervisor post "/store/addons/${ADDON_SLUG}/install" '{}' >/dev/null
  for _ in $(seq 1 60); do
    sleep 3
    ver="$(addon_version)"
    [[ -n "$ver" ]] && break
  done
  if [[ -z "$ver" ]]; then
    echo "Add-on did not finish installing within timeout." >&2
    exit 1
  fi
fi
echo "Add-on installed (version ${ver})."

# Build options. The Advanced SSH add-on schema nests ssh-related fields
# under the "ssh" key. ssh.username MUST be set to a valid Unix username
# (typically "root"); if left blank Supervisor may auto-fill from the SSH
# key comment, which is invalid and crashes the SSH daemon at start.
echo "Writing add-on options (ssh.username=root, authorized_keys, port 22222)..."
options_json="$(python3 - "${pubkey}" <<'PY'
import json, sys
pubkey = sys.argv[1].strip()
print(json.dumps({
    "options": {
        "ssh": {
            "username": "root",
            "password": "",
            "authorized_keys": [pubkey],
            "sftp": False,
            "compatibility_mode": False,
            "allow_agent_forwarding": False,
            "allow_remote_port_forwarding": False,
            "allow_tcp_forwarding": False,
        },
        "zsh": True,
        "share_sessions": False,
        "packages": [],
        "init_commands": [],
    },
    # Map the container port 22 to host port 22222.
    "network": {"22/tcp": 22222},
}))
PY
)"
ha_supervisor post "/addons/${ADDON_SLUG}/options" "$options_json" >/dev/null

echo "Restarting add-on so the new options take effect..."
ha_supervisor post "/addons/${ADDON_SLUG}/restart" '{}' >/dev/null

# Poll until the SSH daemon inside the add-on is actually accepting
# connections. Without this, an immediate `ssh` from the next line of a
# user's script fails with "Connection refused" because the addon container
# is still coming back up.
ssh_host="${HA_HOST%%:*}"
echo "Waiting for SSH on ${ssh_host}:22222..."
for i in $(seq 1 30); do
  if (exec 3<>"/dev/tcp/${ssh_host}/22222") 2>/dev/null; then
    exec 3<&-
    echo "SSH up after ${i}s."
    break
  fi
  sleep 1
done

echo "Done. Test with:  ssh root@${ssh_host} -p 22222"
