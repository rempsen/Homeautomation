#!/usr/bin/env bash
# Reusable curl wrapper for the Home Assistant REST API.
# Source this file from other scripts: . "$(dirname "$0")/ha-api.sh"
#
# Required env vars:
#   HA_HOST   host:port of HA, e.g. homeassistant.local:8123
#   HA_TOKEN  long-lived access token (Profile > Security in HA UI)
#
# Optional:
#   HA_SCHEME http (default) or https

set -euo pipefail

: "${HA_HOST:?set HA_HOST, e.g. homeassistant.local:8123}"
: "${HA_TOKEN:?set HA_TOKEN to a long-lived access token}"
HA_SCHEME="${HA_SCHEME:-http}"

ha_api() {
  # ha_api METHOD PATH [JSON_BODY]
  local method="$1" path="$2" body="${3-}"
  local url="${HA_SCHEME}://${HA_HOST}${path}"
  local args=(
    --fail-with-body -sS
    -X "$method"
    -H "Authorization: Bearer ${HA_TOKEN}"
    -H "Content-Type: application/json"
    "$url"
  )
  if [[ -n "$body" ]]; then
    args+=(-d "$body")
  fi
  curl "${args[@]}"
}

ha_ping() {
  ha_api GET /api/ >/dev/null
  echo "HA reachable at ${HA_SCHEME}://${HA_HOST}"
}

export -f ha_api ha_ping
