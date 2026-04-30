#!/usr/bin/env bash
# Reusable HA API wrappers. Source this file from other scripts:
#   . "$(dirname "$0")/ha-api.sh"
#
# Required env vars:
#   HA_HOST   host:port of HA, e.g. homeassistant.local:8123
#   HA_TOKEN  long-lived access token (Profile > Security in the HA UI)
#
# Optional:
#   HA_SCHEME http (default) or https

set -euo pipefail

: "${HA_HOST:?set HA_HOST, e.g. homeassistant.local:8123}"
: "${HA_TOKEN:?set HA_TOKEN to a long-lived access token}"
HA_SCHEME="${HA_SCHEME:-http}"

# Regular HA REST API call. Use this for endpoints under /api/ that aren't
# the Supervisor proxy: /api/, /api/services/..., /api/config/..., etc.
ha_api() {
  local method="$1" path="$2" body="${3-}"
  local url="${HA_SCHEME}://${HA_HOST}${path}"
  local args=(
    --fail-with-body -sS
    -X "$method"
    -H "Authorization: Bearer ${HA_TOKEN}"
    -H "Content-Type: application/json"
    "$url"
  )
  [[ -n "$body" ]] && args+=(-d "$body")
  curl "${args[@]}"
}

ha_ping() {
  ha_api GET /api/ >/dev/null
  echo "HA reachable at ${HA_SCHEME}://${HA_HOST}"
}

# Supervisor API call via WebSocket. Used instead of the HTTP /api/hassio/...
# proxy because Home Assistant Core 2024.x+ rejects long-lived access tokens
# at that proxy with HTTP 401, even when the user is an admin. The WebSocket
# "supervisor/api" command accepts the same token without that restriction.
#
# Usage:
#   ha_supervisor <get|post|put|delete> <endpoint> [<json-body>]
# Example:
#   ha_supervisor get /addons/a0d7b954_ssh/info
#   ha_supervisor post /addons/core_git_pull/options '{"options":{...}}'
#
# On success, writes the "result" field of the response to stdout as JSON.
# On failure, writes the error to stderr and exits non-zero.
ha_supervisor() {
  local method="$1" endpoint="$2" body="${3-}"
  HA_WS_METHOD="$method" HA_WS_ENDPOINT="$endpoint" HA_WS_BODY="$body" \
    python3 - <<'PY'
import json, os, socket, base64, secrets, struct, sys

host_port = os.environ["HA_HOST"]
token     = os.environ["HA_TOKEN"]
method    = os.environ["HA_WS_METHOD"].lower()
endpoint  = os.environ["HA_WS_ENDPOINT"]
body_raw  = os.environ.get("HA_WS_BODY", "") or ""
body      = json.loads(body_raw) if body_raw.strip() else None

host, _, port = host_port.partition(":")
port = int(port) if port else 8123

def ws_connect():
    s = socket.create_connection((host, port), timeout=20)
    key = base64.b64encode(secrets.token_bytes(16)).decode()
    s.sendall(
        f"GET /api/websocket HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        f"Upgrade: websocket\r\nConnection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
        .encode()
    )
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            sys.exit("ws upgrade: connection closed by peer")
        buf += chunk
    head, _, rest = buf.partition(b"\r\n\r\n")
    if b"101" not in head.split(b"\r\n", 1)[0]:
        sys.exit(f"ws upgrade failed: {head[:160]!r}")
    return s, rest

def ws_send(sock, text):
    data = text.encode()
    mask = secrets.token_bytes(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
    header = bytes([0x81])
    L = len(data)
    if L < 126:
        header += bytes([0x80 | L])
    elif L < 65536:
        header += bytes([0x80 | 126]) + struct.pack("!H", L)
    else:
        header += bytes([0x80 | 127]) + struct.pack("!Q", L)
    sock.sendall(header + mask + masked)

def ws_recv(sock, buf):
    def need(n):
        nonlocal buf
        while len(buf) < n:
            chunk = sock.recv(65536)
            if not chunk:
                raise EOFError("ws closed mid-frame")
            buf += chunk
    need(2)
    _, b2 = buf[0], buf[1]
    masked = b2 & 0x80
    L = b2 & 0x7F
    offset = 2
    if L == 126:
        need(offset + 2); L = struct.unpack("!H", buf[offset:offset+2])[0]; offset += 2
    elif L == 127:
        need(offset + 8); L = struct.unpack("!Q", buf[offset:offset+8])[0]; offset += 8
    if masked:
        need(offset + 4); mk = buf[offset:offset+4]; offset += 4
    need(offset + L)
    payload = buf[offset:offset + L]
    if masked:
        payload = bytes(b ^ mk[i % 4] for i, b in enumerate(payload))
    return payload.decode(), buf[offset + L:]

sock, buf = ws_connect()
_, buf = ws_recv(sock, buf)  # auth_required hello
ws_send(sock, json.dumps({"type": "auth", "access_token": token}))
ack, buf = ws_recv(sock, buf)
if json.loads(ack).get("type") != "auth_ok":
    sys.exit(f"ws auth failed: {ack}")

msg = {"id": 1, "type": "supervisor/api", "endpoint": endpoint, "method": method}
if body is not None:
    msg["data"] = body
ws_send(sock, json.dumps(msg))

# Some Supervisor calls (addon install, in particular) can take 30-180s.
# Raise the recv timeout so we don't bail before the response arrives.
sock.settimeout(300)
resp, buf = ws_recv(sock, buf)
sock.close()
data = json.loads(resp)
if not data.get("success"):
    err = data.get("error", {})
    sys.exit(f"supervisor/{method} {endpoint} failed: {err}")
result = data.get("result")
sys.stdout.write(json.dumps(result) if result is not None else "")
PY
}

export -f ha_api ha_ping ha_supervisor
