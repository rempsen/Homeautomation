#!/usr/bin/env bash
# Reconcile the HACS install on the Green with hacs.yaml in this repo.
# For each entry: resolve the HACS catalog ID and download via the
# HACS WebSocket command `hacs/repository/download`.
#
# Inputs (env):
#   HA_HOST, HA_TOKEN  see ha-api.sh
#
# This replaces an earlier implementation that called
#   ha core ws --raw '<json>'
# from inside the SSH addon — the `ws` subcommand does not exist on
# HA OS. Driving the WebSocket directly from the workstation works
# regardless of HA version and surfaces real per-entry errors.
#
# Requires `pyyaml` locally (`pip3 install --user pyyaml`).

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ha-api.sh
source "${HERE}/ha-api.sh"

manifest="${HERE}/../hacs.yaml"
[[ -f "${manifest}" ]] || { echo "hacs.yaml not found at ${manifest}" >&2; exit 1; }

ha_ping

HA_HACS_MANIFEST="${manifest}" python3 - <<'PY'
import json, os, socket, base64, secrets, struct, sys

try:
    import yaml
except ImportError:
    print("pyyaml is required: pip3 install --user pyyaml", file=sys.stderr)
    sys.exit(2)

with open(os.environ["HA_HACS_MANIFEST"]) as f:
    data = yaml.safe_load(f) or {}
entries = data.get("entries") or []

if not entries:
    print("hacs.yaml has no entries; nothing to sync.")
    sys.exit(0)

print(f"Syncing {len(entries)} HACS entry/entries from hacs.yaml...")

host_port = os.environ["HA_HOST"]
token = os.environ["HA_TOKEN"]
host, _, port = host_port.partition(":")
port = int(port) if port else 8123

def ws_connect():
    s = socket.create_connection((host, port), timeout=20)
    key = base64.b64encode(secrets.token_bytes(16)).decode()
    s.sendall(
        f"GET /api/websocket HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        f"Upgrade: websocket\r\nConnection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n".encode()
    )
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            sys.exit("ws upgrade: connection closed")
        buf += chunk
    head, _, rest = buf.partition(b"\r\n\r\n")
    if b"101" not in head.split(b"\r\n", 1)[0]:
        sys.exit(f"ws upgrade failed: {head[:160]!r}")
    return s, rest

def ws_send(sock, text):
    data = text.encode()
    mask = secrets.token_bytes(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
    h = bytes([0x81])
    L = len(data)
    if L < 126: h += bytes([0x80 | L])
    elif L < 65536: h += bytes([0x80 | 126]) + struct.pack("!H", L)
    else: h += bytes([0x80 | 127]) + struct.pack("!Q", L)
    sock.sendall(h + mask + masked)

def ws_recv(sock, buf, timeout=180):
    sock.settimeout(timeout)
    def need(n):
        nonlocal buf
        while len(buf) < n:
            chunk = sock.recv(65536)
            if not chunk: raise EOFError
            buf += chunk
    need(2)
    _, b2 = buf[0], buf[1]; mk = b2 & 0x80; L = b2 & 0x7F; o = 2
    if L == 126: need(o+2); L = struct.unpack("!H", buf[o:o+2])[0]; o += 2
    elif L == 127: need(o+8); L = struct.unpack("!Q", buf[o:o+8])[0]; o += 8
    if mk: need(o+4); k = buf[o:o+4]; o += 4
    need(o + L)
    pl = buf[o:o+L]
    if mk: pl = bytes(b ^ k[i % 4] for i, b in enumerate(pl))
    return pl.decode(), buf[o+L:]

s, buf = ws_connect()
_, buf = ws_recv(s, buf)
ws_send(s, json.dumps({"type": "auth", "access_token": token}))
ack, buf = ws_recv(s, buf)
if json.loads(ack).get("type") != "auth_ok":
    sys.exit(f"ws auth failed: {ack}")

# Get the catalog so we can resolve owner/repo names to internal IDs.
ws_send(s, json.dumps({"id": 1, "type": "hacs/repositories/list"}))
r, buf = ws_recv(s, buf, timeout=60)
data = json.loads(r)
if not data.get("success"):
    sys.exit(f"hacs/repositories/list failed: {data.get('error',{})}")
catalog = data.get("result", [])
by_full = {r.get("full_name"): r for r in catalog if isinstance(r, dict) and r.get("full_name")}

nid = 1
exit_code = 0
for entry in entries:
    repo_full = entry["repository"]
    category  = entry.get("category", "")
    version   = entry.get("version")
    nid += 1

    repo = by_full.get(repo_full)
    if not repo:
        print(f"  SKIP   {repo_full}  not in HACS default catalog "
              f"(would need to be registered as a custom repository first)")
        exit_code = max(exit_code, 1)
        continue

    if repo.get("installed_version"):
        if version and repo["installed_version"] != version:
            print(f"  WARN   {repo_full}  installed v{repo['installed_version']}, "
                  f"hacs.yaml asks for v{version} — version pinning not yet "
                  f"implemented in this script. Skipping.")
        else:
            print(f"  OK     {repo_full}  v{repo['installed_version']}")
        continue

    msg = {"id": nid, "type": "hacs/repository/download", "repository": str(repo["id"])}
    if version:
        msg["version"] = version

    ws_send(s, json.dumps(msg))
    r, buf = ws_recv(s, buf, timeout=180)
    d = json.loads(r)
    if d.get("success"):
        print(f"  INST   {repo_full:50s} v{version or 'latest'}")
    else:
        err = d.get("error", {}).get("message") or d.get("error")
        print(f"  FAIL   {repo_full}  {err}")
        exit_code = max(exit_code, 1)

s.close()
sys.exit(exit_code)
PY

echo
echo "Reloading scripts and frontend themes (cheap; no HA restart)."
ha_api POST /api/services/script/reload          >/dev/null 2>&1 || true
ha_api POST /api/services/frontend/reload_themes >/dev/null 2>&1 || true

cat <<EOF
Done.

Note: any newly downloaded *integrations* (custom_components/<name>/)
require a Home Assistant Core restart before they appear under
Settings → Devices & Services. Trigger one if needed:
  ssh root@${HA_HOST%%:*} -p 22222 'ha core restart'
Newly downloaded *plugins* (Lovelace cards) are picked up at the next
hard browser refresh.
EOF
