# Home Automation — HA Green + Zigbee (CLI-first)

Configuration repo for a Home Assistant Green appliance with the Home
Assistant Connect ZBT-2 Zigbee adapter (ZHA stack). The Green pulls this
repo into `/config` via the **Git Pull** add-on; everything else is driven
from a terminal against the HA REST API.

## Repo layout

```
configuration.yaml         # top-level config; includes the files below
automations.yaml           # add automations here (or in packages/)
scripts.yaml               # add scripts here
scenes.yaml                # add scenes here
secrets.yaml.example       # template; real secrets.yaml is git-ignored
hacs.yaml                  # manifest of HACS-tracked community repos

packages/                  # split-config packages, auto-loaded by HA
dashboards/                # Lovelace YAML dashboards
blueprints/automation/     # automation blueprints (symlinks land here when imported)
third_party/               # git submodules for community YAML repos

scripts/                   # bootstrap helpers (host-side, run from your workstation)
  ha-api.sh                # curl wrapper sourced by the others
  bootstrap-ssh-addon.sh   # install + start the Advanced SSH add-on
  install-git-pull-addon.sh# install + configure the Git Pull add-on
  configure-zha.sh         # create the ZHA config entry against the adapter
  install-hacs.sh          # install HACS over SSH and register it
  hacs-sync.sh             # reconcile the Green's HACS install with hacs.yaml
  import-repo.sh           # add a community repo as a submodule + wire it in
```

## One-time prerequisites

1. **Onboard the Green** through the web UI at
   `http://homeassistant.local:8123` (one-time owner account + region).
2. **Create a long-lived access token** at *Profile → Security → Long-lived
   access tokens*. Copy it once; HA won't show it again.
3. **Plug in the ZBT-2** before running `configure-zha.sh`.
4. **Reachability**: run the scripts below from a workstation on the same
   LAN as the Green.

## Bootstrap

```bash
export HA_HOST=homeassistant.local:8123     # or the Green's static IP
export HA_TOKEN=<long-lived-access-token>

# 1. Open SSH on port 22222 using your local public key.
./scripts/bootstrap-ssh-addon.sh

# 2. Configure the Git Pull add-on to track this repo.
export GIT_REPO=https://github.com/rempsen/homeautomation
export GIT_BRANCH=main
./scripts/install-git-pull-addon.sh

# 3. Wire ZHA to the ZBT-2 adapter.
./scripts/configure-zha.sh

# 4. (Optional) Install HACS for community integrations / Lovelace plugins.
./scripts/install-hacs.sh
```

After step 2, this repo is `/config` on the Green. Workflow becomes:

```
edit YAML  ->  git commit && git push
           ->  curl -X POST -H "Authorization: Bearer $HA_TOKEN" \
                    http://$HA_HOST/api/hassio/addons/core_git_pull/start
           ->  curl -X POST -H "Authorization: Bearer $HA_TOKEN" \
                    http://$HA_HOST/api/services/automation/reload
```

## Pairing Zigbee devices from the CLI

```bash
# Open the network for 60 s, then put the device into pair mode.
curl -fsSL -X POST \
  -H "Authorization: Bearer $HA_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"duration":60}' \
  "http://$HA_HOST/api/services/zha/permit"

# List newly added entities.
curl -fsSL -H "Authorization: Bearer $HA_TOKEN" \
  "http://$HA_HOST/api/states" \
  | jq '.[] | select(.entity_id | startswith("light.") or startswith("sensor."))'

# Remove a device by IEEE address.
curl -fsSL -X POST \
  -H "Authorization: Bearer $HA_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"ieee":"xx:xx:xx:xx:xx:xx:xx:xx"}' \
  "http://$HA_HOST/api/services/zha/remove"
```

## Importing other GitHub repos and blending them in

Two paths, deliberately different because HA stores YAML and Python in
different places.

### Path A — YAML repos (blueprints, packages, dashboards)

```bash
# Blueprint pack:
./scripts/import-repo.sh https://github.com/example/awesome-blueprints blueprint awesome

# Package bundle:
./scripts/import-repo.sh https://github.com/example/lights-package package lights

# Anything else (no auto-wiring):
./scripts/import-repo.sh https://github.com/example/widgets other widgets
```

`import-repo.sh` adds the upstream as a submodule under `third_party/` and
creates the right symlink or `!include` so HA picks it up after the next
Git Pull. To update upstream later:

```bash
git submodule update --remote -- third_party/<name>
git commit -am "bump third_party/<name>"
git push
```

### Path B — Python integrations / Lovelace JS plugins (HACS)

These live in `/config/custom_components/` and `/config/www/community/` on
the Green and are managed by HACS. Add an entry to `hacs.yaml`:

```yaml
entries:
  - repository: thomasloven/lovelace-card-mod
    category: plugin
    version: 3.4.4
```

Then run:

```bash
./scripts/hacs-sync.sh
```

`custom_components/` and `www/community/` are git-ignored — the manifest in
`hacs.yaml` is the source of truth for *which* community code is installed,
HACS handles the *how*.

## Troubleshooting

```bash
# Validate /config:
ssh root@${HA_HOST%%:*} -p 22222 'ha core check'

# Tail Core logs:
curl -fsSL -H "Authorization: Bearer $HA_TOKEN" \
  "http://$HA_HOST/api/error_log"

# Inspect an add-on's logs:
curl -fsSL -H "Authorization: Bearer $HA_TOKEN" \
  "http://$HA_HOST/api/hassio/addons/core_git_pull/logs"
```
