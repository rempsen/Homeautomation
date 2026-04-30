#!/usr/bin/env bash
# Install and configure the "Home Assistant Git Pull" add-on so the Green
# pulls this repo into /config on demand.
#
# Inputs (env):
#   HA_HOST, HA_TOKEN  see ha-api.sh
#   GIT_REPO           e.g. https://github.com/rempsen/homeautomation
#   GIT_BRANCH         e.g. main                (default: main)
#   GIT_DEPLOY_KEY     optional: path to a private SSH deploy key
#                      (only needed for private repos)
#
# Notes:
#   - Add-on slug: core_git_pull. Tested against v9.0.1.
#   - The official Git Pull add-on does NOT honor custom git args, so it
#     does not recurse into submodules. If you rely on submodules, run
#     `git submodule update --init --recursive` over SSH after each pull,
#     or vendor the upstream code directly.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ha-api.sh
source "${HERE}/ha-api.sh"

: "${GIT_REPO:?set GIT_REPO to the GitHub URL of this repo}"
GIT_BRANCH="${GIT_BRANCH:-main}"
ADDON_SLUG="core_git_pull"

deploy_key_content=""
if [[ -n "${GIT_DEPLOY_KEY:-}" ]]; then
  if [[ ! -f "${GIT_DEPLOY_KEY}" ]]; then
    echo "GIT_DEPLOY_KEY=${GIT_DEPLOY_KEY} not found" >&2
    exit 1
  fi
  deploy_key_content="$(< "${GIT_DEPLOY_KEY}")"
fi

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

echo "Writing Git Pull options (repo=${GIT_REPO}, branch=${GIT_BRANCH})..."
# Schema as of core_git_pull v9.0.1:
#   repository, git_branch, git_remote, auto_restart, restart_ignore[],
#   git_command (pull|reset), git_prune, deployment_key[], deployment_user,
#   deployment_password, deployment_key_protocol, repeat{active,interval}
options_json="$(python3 - "$GIT_REPO" "$GIT_BRANCH" "$deploy_key_content" <<'PY'
import json, sys
repo, branch, deploy_key = sys.argv[1], sys.argv[2], sys.argv[3]
opts = {
    "repository": repo,
    "git_branch": branch,
    "git_remote": "origin",
    "auto_restart": False,
    "restart_ignore": ["ui-lovelace.yaml", ".gitignore"],
    "git_command": "pull",
    "git_prune": True,
    "deployment_key": [deploy_key] if deploy_key.strip() else [],
    "deployment_user": "",
    "deployment_password": "",
    "deployment_key_protocol": "rsa",
    "repeat": {"active": False, "interval": 300},
}
print(json.dumps({"options": opts}))
PY
)"
ha_supervisor post "/addons/${ADDON_SLUG}/options" "$options_json" >/dev/null

echo "Starting add-on (this performs the first pull)..."
ha_supervisor post "/addons/${ADDON_SLUG}/start" '{}' >/dev/null

echo "Validating /config after first sync..."
ha_api POST /api/services/homeassistant/check_config >/dev/null

cat <<EOM
Done.

Trigger a manual pull later from the workstation (over SSH, since the
Supervisor HTTP proxy is locked down for long-lived tokens):
  ssh root@${HA_HOST%%:*} -p 22222 'ha addons start ${ADDON_SLUG}'
EOM
