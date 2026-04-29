#!/usr/bin/env bash
# Reconcile the HACS install on the Green with hacs.yaml in this repo.
# For each entry: download the requested version into the right HACS dir.
#
# Inputs (env):
#   HA_HOST, HA_TOKEN  see ha-api.sh
#
# Note:
#   HACS does not expose a fully public "install repo X at version Y" REST
#   endpoint that's stable across versions. The pragmatic approach is to
#   call the websocket API via `ha` CLI on the Green over SSH.
#   This script generates the equivalent commands and runs them remotely.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ha-api.sh
source "${HERE}/ha-api.sh"

HA_SSH_HOST="${HA_SSH_HOST:-${HA_HOST%%:*}}"
HA_SSH_PORT="${HA_SSH_PORT:-22222}"
HA_SSH_USER="${HA_SSH_USER:-root}"

manifest="${HERE}/../hacs.yaml"
[[ -f "${manifest}" ]] || { echo "hacs.yaml not found at ${manifest}" >&2; exit 1; }

count="$(python3 -c '
import sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f) or {}
print(len(data.get("entries") or []))
' "${manifest}")"

if [[ "${count}" == "0" ]]; then
  echo "hacs.yaml has no entries; nothing to sync."
  exit 0
fi

echo "Syncing ${count} HACS entry/entries from ${manifest}..."

python3 - "${manifest}" <<'PY' | ssh -p "${HA_SSH_PORT}" "${HA_SSH_USER}@${HA_SSH_HOST}" 'bash -s'
import sys, yaml, shlex
with open(sys.argv[1]) as f:
    entries = (yaml.safe_load(f) or {}).get("entries") or []
print("set -euo pipefail")
for e in entries:
    repo     = e["repository"]
    category = e["category"]
    version  = e.get("version", "")
    # Use the HACS websocket API via ha CLI. The hacs/repository/download
    # message accepts {repository, category, version}.
    msg = {
        "type": "hacs/repository/download",
        "repository": repo,
        "category": category,
    }
    if version:
        msg["version"] = version
    print(f"echo '>> {repo} ({category}) -> {version or 'latest'}'")
    print(f"ha core ws --raw {shlex.quote(__import__('json').dumps(msg))}")
PY

echo "Restarting Home Assistant Core to load any new integrations..."
ha_api POST /api/services/homeassistant/restart >/dev/null || true
echo "Done."
