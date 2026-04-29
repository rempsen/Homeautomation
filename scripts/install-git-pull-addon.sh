#!/usr/bin/env bash
# Install and configure the "Home Assistant Git Pull" add-on so the Green
# pulls this repo (with submodules) into /config on demand.
#
# Inputs (env):
#   HA_HOST, HA_TOKEN  see ha-api.sh
#   GIT_REPO           e.g. https://github.com/rempsen/homeautomation
#   GIT_BRANCH         e.g. main                (default: main)
#   GIT_DEPLOY_KEY     optional: path to a private SSH deploy key
#                      (only needed for private repos)
#
# Notes:
#   - Add-on slug for the official community Git Pull add-on is "core_git_pull".
#   - We enable recurse-submodules so third_party/ submodules ride along.

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

state="$(ha_api GET "/api/hassio/addons/${ADDON_SLUG}/info" 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("data",{}).get("state","not_installed"))' \
  || echo not_installed)"

if [[ "${state}" == "not_installed" ]]; then
  echo "Installing add-on ${ADDON_SLUG}..."
  ha_api POST "/api/hassio/addons/${ADDON_SLUG}/install" >/dev/null
fi

echo "Writing Git Pull options (repo=${GIT_REPO}, branch=${GIT_BRANCH})..."
options_json=$(python3 - "$GIT_REPO" "$GIT_BRANCH" "$deploy_key_content" <<'PY'
import json, sys
repo, branch, deploy_key = sys.argv[1], sys.argv[2], sys.argv[3]
opts = {
    "repository": repo,
    "auto_update": False,
    "repeat": {"active": False, "interval": 60},
    "git_branch": branch,
    "git_command": "pull",
    "git_remote": "origin",
    "git_prune": True,
    "restart_ignored_files": [],
    # The community Git Pull add-on supports submodules transparently when
    # using its default `pull` command; we add an explicit recurse arg as
    # an extra git argument.
    "git_extra_args": ["--recurse-submodules"],
}
if deploy_key.strip():
    opts["deployment_key"] = deploy_key
print(json.dumps({"options": opts}))
PY
)
ha_api POST "/api/hassio/addons/${ADDON_SLUG}/options" "${options_json}" >/dev/null

echo "Starting add-on (this performs the first pull)..."
ha_api POST "/api/hassio/addons/${ADDON_SLUG}/start" >/dev/null || true

echo "Validating /config after first sync..."
ha_api POST "/api/services/homeassistant/check_config" >/dev/null

echo "Done. To trigger a manual pull later:"
echo "  curl -fsSL -X POST -H \"Authorization: Bearer \$HA_TOKEN\" \\"
echo "       \"http://\$HA_HOST/api/hassio/addons/${ADDON_SLUG}/start\""
