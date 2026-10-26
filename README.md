# UniFi PTZ Better Patrol

Motion aware patrol for UniFi Protect PTZ cameras. Cycles through saved presets, holds for detected activity, and backs off when manual camera movement is detected. Runs on the UniFi OS console using Bash, curl, jq and systemd.

## What this change adds

- Site Manager API key authentication through the Cloud Connector, alongside existing local administrator authentication.
- Interactive setup that lists accessible hosts, discovers cameras and presets, and creates the patrol configuration.
- A repository bootstrap script that downloads the required files before starting setup.
- Explicit documentation of reboot startup and firmware recovery requirements.

Both modes use Protect's **private API**. Cloud mode is not a rewrite using only the official Integration API. Changes to private endpoints can affect compatibility.

## Compatibility

| Path | Evidence |
| --- | --- |
| Upstream local mode | Upstream documents G5 PTZ and G6 PTZ deployments on UniFi OS consoles. |
| Cloud mode and initial wizard | User reported successful discovery, installation and patrol with two G5 PTZ cameras on UDM Pro, UniFi OS 6.0.15 and Protect 7.3.70. |
| Latest local setup option and repository bootstrap | Offline checks only; hardware validation remains outstanding. |
| Reboot and firmware recovery | Service enablement and hook creation inspected. Actual reboot and firmware upgrade tests remain outstanding. |

The hardware report does not establish every motion, manual control, scheduling or recovery scenario. See [tests/README.md](tests/README.md) for upstream fixture provenance and [docs/operations.md](docs/operations.md) for implementation details and historical field reports.

## Requirements

- A UniFi OS console with Protect, SSH access, root privileges and systemd.
- At least two saved presets on each connected PTZ camera discovered during initial setup.
- Either a Site Manager API key with access to the console, or a local administrator with Protect permissions.
- Internet access for cloud mode. Local mode sends patrol requests directly to the configured NVR.

The installer installs curl/jq dependencies when needed. Cloud mode verifies TLS certificates; local mode retains upstream handling of self-signed NVR certificates.

## Authentication

| Mode | Wizard inputs | Connection |
| --- | --- | --- |
| Cloud | Site Manager API key, then host selection | `api.ui.com` Cloud Connector |
| Local | NVR HTTPS URL, local username and password | Direct NVR connection |

Create a cloud key in Site Manager under Settings → API Keys, in the organization containing the console. The key is requested first because host discovery requires authentication. The wizard lists the hosts accessible to that key, then validates Protect access on your selection. No console ID needs to be copied manually.

Cloud latency and request limits can affect response time. The existing frequent polling has not been optimized or load tested for large cloud deployments. A revoked key must be replaced; retrying cannot renew it.

## Install

### From a downloaded package or checkout

Copy the complete directory to your console, then run from an SSH terminal:

```bash
cd /data/unifi-ptz-cloud-adaptation
bash install.sh
```

If using a Git checkout instead of the ZIP, change to that checkout's directory. The standalone `install.sh` requires its companion files.

The wizard will:

1. Offer to reuse existing settings, if installed.
2. Ask for cloud or local authentication.
3. List cloud hosts for selection, or request the local NVR URL and credentials.
4. Validate access and display discovered PTZ cameras and presets.
5. Offer to save the configuration.
6. Offer to start patrol and enable startup at boot.

New installations use all discovered cameras and presets. Setup stops if no PTZ cameras are found or a discovered camera has fewer than two presets. Existing configuration reuse preserves custom values.

### From a published repository

These commands require a fork or branch containing **all files in this change**, including `bootstrap.sh` and `setup.sh`. They do not work against upstream main until merged. Replace `OWNER/REPO` and `REF` with the published repository and branch, tag or commit.

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/REF/bootstrap.sh \
  -o /tmp/ptz-bootstrap.sh
sudo env PTZ_PATROL_REPO=OWNER/REPO PTZ_PATROL_REF=REF \
  bash /tmp/ptz-bootstrap.sh
```

For a pipe installation:

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/REF/bootstrap.sh \
  | sudo env PTZ_PATROL_REPO=OWNER/REPO PTZ_PATROL_REF=REF bash
```

Prompts read from `/dev/tty`, so an interactive terminal is required. Review scripts before executing them as root. Use an immutable commit for reproducible downloads; this launcher does not verify a signed release or checksum manifest.

### Upgrade an existing installation

Run the installer from the new complete package and accept **Keep existing configuration**. It validates discovery, stops the running service, copies the new files, and asks whether to start it again. Choosing not to start leaves patrol stopped and disables its boot registration and recovery hook.

This candidate changes the installer interface: the former `--nvr`, `--username`, `--password` and `PTZ_PATROL_BRANCH` installation inputs are not supported. Use the wizard and bootstrap variables above. Existing runtime configurations remain supported; missing `auth_mode` defaults to `local`. This installer interface change needs maintainer review before merging.

## Default patrol behavior

| Setting | New installation default |
| --- | --- |
| Presets | All discovered presets, in slot order |
| Dwell | 30 seconds |
| Motion hold | 15 seconds |
| Maximum tracking wait | 300 seconds |
| Manual control hold | 120 seconds |
| Settling interval | 10 seconds, capped at half the dwell |
| Person tracking management | Enabled |
| Schedule | Continuous |
| Return home between cycles / on shutdown | Disabled |
| Rediscovery | Every 600 seconds |

Dwell is extended or interrupted by activity, tracking or manual control. Manual control is inferred from position changes, not an explicit operator-control API flag.

**Starting patrol changes camera settings.** It attempts to stop built-in patrols and disable automatic return to home. With `dynamic_auto_tracking` enabled, it resets tracking on startup, enables person tracking for patrol, and attempts to disable tracking on schedule pause and shutdown. Re-enable person tracking in Protect if returning to normal camera operation. Previous return-home and built-in patrol settings are not automatically restored.

## Configuration

Settings are stored in `/data/ptz-patrol/config.json`, with mode `0600`. Do not commit or share that file or its backups. The wizard keeps credentials out of prompts' visible output; cloud requests use a private temporary header file instead of putting the API key in curl arguments.

Cloud authentication fields:

```json
{
  "auth_mode": "cloud",
  "api_key": "YOUR_SITE_MANAGER_API_KEY",
  "console_id": "SELECTED_HOST_ID"
}
```

Local authentication fields:

```json
{
  "auth_mode": "local",
  "nvr_address": "https://127.0.0.1",
  "username": "patrol",
  "password": "YOUR_LOCAL_PASSWORD"
}
```

These are excerpts, not complete configurations. Keep the `defaults` and other settings generated by setup. See [config.json.example](config.json.example) for the complete template. `dynamic_auto_tracking` defaults to true in the new template; an older config omitting it retains the runtime fallback of false.

### Camera overrides

Add overrides by camera ID under `camera_overrides`:

```json
{
  "camera_overrides": {
    "CAMERA_ID": {
      "dwell_seconds": 45,
      "preset_slots": [0, 2],
      "dynamic_auto_tracking": true
    },
    "ANOTHER_CAMERA_ID": {
      "enabled": false
    }
  }
}
```

Overrides merge with `defaults`. Omitting `preset_slots` uses all discovered presets. Run discovery to obtain camera IDs and preset slots without moving cameras:

```bash
bash /data/ptz-patrol/discover.sh
```

### Schedules

Add a schedule under `defaults` or a camera override:

```json
{
  "schedule": {
    "start": "22:00",
    "end": "06:00",
    "days": ["mon", "tue", "wed", "thu", "fri"],
    "home_on_pause": true
  }
}
```

Times use the console's system clock; check `date`. Overnight ranges are supported. A null schedule means continuous operation.

After editing, validate syntax without displaying credentials and restart:

```bash
jq empty /data/ptz-patrol/config.json && systemctl restart ptz-patrol.service
```

## Service management

```bash
systemctl status ptz-patrol.service
journalctl -u ptz-patrol.service -n 80 -f
systemctl stop ptz-patrol.service
systemctl start ptz-patrol.service
```

Ctrl+C exits the log viewer without stopping patrol. Log levels are `error`, `warn`, `info` and `debug`, configured by `log_level`. The textual severity prefixes are not mapped to journald priorities; use the log text when filtering.

## Reboots and firmware updates

**Ordinary reboot:** accepting startup in the installer enables the systemd service. Verify with:

```bash
systemctl is-enabled ptz-patrol.service
```

**UniFi OS firmware upgrade:** scripts, config and a service template are stored under `/data/ptz-patrol`. The installer can create `/data/on_boot.d/10-ptz-patrol.sh` to restore dependencies and the systemd service. However, a separate functioning boot runner must execute that hook. Creating the directory and script does not install a runner.

Automatic firmware recovery is **not guaranteed or verified on UniFi OS 6**. The original hook design has the same dependency. This project does not install or certify a third-party boot runner. A Protect application update is distinct from a UniFi OS firmware upgrade; either can introduce private API incompatibilities.

Check common runners:

```bash
systemctl list-unit-files --type=service | grep -E 'udm-boot|unifi-on-boot'
ls -l /data/on_boot.d/10-ptz-patrol.sh
```

No matching service means those runners were not found, not proof that no other mechanism exists. If files survive but service registration is lost, recover manually:

```bash
bash /data/ptz-patrol/install.sh --bootstrap
systemctl restart ptz-patrol.service
systemctl --no-pager status ptz-patrol.service
```

To disable all startup paths, stop/disable the service and remove the hook:

```bash
systemctl disable --now ptz-patrol.service
rm -f /data/on_boot.d/10-ptz-patrol.sh
```

## Troubleshooting

| Symptom | Check |
| --- | --- |
| HTTP 401 or 403 | Key validity, organization, selected console and permissions; for local mode, local account credentials. |
| HTTP 404 | Private endpoint compatibility with the installed Protect version. |
| HTTP 429 or slow response | Cloud request limits or latency. Stop patrol and inspect logs before increasing load. |
| No cameras | Selected host runs Protect, cameras are connected and recognized as PTZ. |
| Fewer than two presets | Save at least two presets in Protect, then rerun setup. |
| Service stopped after setup | Accept the final startup prompt, or start and enable the service manually. |
| Firmware update removed service | Check the boot runner and use manual bootstrap above if files remain. |

Do not post API keys, passwords, full config files or config backups in issues. Include console model, UniFi OS version, Protect version, camera model and redacted logs.

## Removal

```bash
bash /data/ptz-patrol/uninstall.sh
```

This removes the installed directory, service and hook. It does not remove separately uploaded source folders or their credential backups. Remove those separately if no longer needed. Camera settings changed by patrol require manual review afterward.

## Development

```bash
shellcheck -s bash api.sh discover.sh patrol.sh ptz-patrol.sh install.sh setup.sh bootstrap.sh uninstall.sh
npm install --prefix tests/.bats bats@1.13.0 --no-audit --no-fund
tests/.bats/node_modules/.bin/bats tests/
bash tests/cloud-auth.sh
python3 tests/test_setup.py
```

The candidate passes the 49 upstream Bats tests, mock cloud checks and two wizard tests. Offline tests do not establish firmware recovery, cloud load behavior or all camera interactions.

| File | Responsibility |
| --- | --- |
| `bootstrap.sh` | Download complete repository files into a temporary directory and launch setup. |
| `install.sh` | Install files, service and optional startup hook; firmware bootstrap mode. |
| `setup.sh` | Interactive authentication, host selection and config generation. |
| `api.sh` | Authentication, HTTP calls, state reads and detection helpers. |
| `discover.sh` | Find PTZ cameras and preset positions. |
| `patrol.sh` | Per-camera patrol and hold behavior. |
| `ptz-patrol.sh` | Process supervision, startup and shutdown. |
| `uninstall.sh` | Remove installed components. |

## Credits & Acknowledgments

- **Original Concept**: [Jason Tucker — Adding Tour/Patrol Mode to UniFi G5 PTZ](https://jasontucker.blog/adding-a-tour-or-patrol-mode-to-unifi-g5-ptz-using-home-assistant/)
- **API Research**: [uiprotect](https://github.com/uilibs/uiprotect) — Unofficial Python API for UniFi Protect
- **Architecture**: Based on patterns from [ucg-max-fan-control](https://github.com/iceteaSA/ucg-max-fan-control)
- **PTZ State Discussion**: [uiprotect #436](https://github.com/uilibs/uiprotect/issues/436), [HA #142129](https://github.com/home-assistant/core/pull/142129)

---

If this project is useful to you, consider supporting continued development:

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/H2H719VB0U)

---

**Disclaimer**: This is a community project — not affiliated with or endorsed by Ubiquiti Inc. The authors accept no liability for hardware damage, motor wear, reduced camera lifespan, or any other consequences of using this software. PTZ cameras are mechanical devices; continuous automated patrol increases wear on pan/tilt/zoom motors beyond typical manual use. Use at your own risk.

**License**: MIT
