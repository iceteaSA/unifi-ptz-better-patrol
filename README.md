# UniFi PTZ Better Patrol

[![CI](https://github.com/iceteaSA/unifi-ptz-better-patrol/actions/workflows/ci.yml/badge.svg)](https://github.com/iceteaSA/unifi-ptz-better-patrol/actions/workflows/ci.yml)

Motion-aware PTZ camera patrol system for Ubiquiti UniFi Protect devices running UniFi OS.

Confirmed working on: UDM, UDR, UNVR (any device running UniFi Protect with PTZ cameras)

Tested with: **G5 PTZ** and **G6 PTZ** cameras only. Other UniFi PTZ models may work but are untested.

> **Warning — Use at your own risk.** This software continuously moves PTZ cameras through preset positions. The pan/tilt motors in some cameras (particularly the G5 PTZ) may not be rated for sustained, continuous patrol operation. Extended use could accelerate motor wear or cause mechanical failure. The authors take no responsibility for any hardware damage, reduced camera lifespan, or warranty implications. **You have been warned.**

## Features

- **Motion-Aware Patrol**: Automatically pauses patrol when motion or smart detection is active
- **Manual Control Detection**: Detects when you're controlling the camera via the Protect app (any axis — pan, tilt, or zoom) and backs off — won't interrupt your PTZ session
- **Active Dwell Monitoring**: Polls for external control and motion during dwell with adaptive intervals — reacts within seconds, not minutes
- **Auto-Tracking Compatible**: Auto-tracking works with this patrol mode — patrol pauses while the camera tracks a subject and resumes when done. UniFi's built-in patrol mode does not support auto-tracking.
- **Dynamic Auto-Tracking**: Optionally enables auto-tracking once at patrol start so the camera can immediately track a person at any preset — no per-preset toggling overhead
- **Auto-Setup**: Automatically disables conflicting Protect settings on startup (built-in patrols, return-to-home, and static auto-tracking when dynamic mode is enabled)
- **Auto-Discovery**: Finds all connected PTZ cameras and their preset positions automatically
- **Per-Camera Overrides**: Customize dwell time, motion hold, and preset slots per camera
- **Optional Patrol Schedule**: Restrict patrol to specific time windows and days of the week, with optional "go home" when paused
- **Parallel Patrol Loops**: Each camera runs its own independent patrol process with isolated auth
- **Configurable Log Levels**: Control verbosity with `error`, `warn`, `info`, or `debug`
- **Max Wait Protection**: Configurable timeout prevents indefinite tracking holds
- **Resilient Operation**: Automatic retry with exponential backoff, per-camera restart on errors
- **Graceful Shutdown**: Clean SIGTERM handling with optional "go home" on service stop
- **Re-Auth Handling**: Transparent token refresh keeps long-running patrols alive
- **Firmware Update Survival**: `on_boot.d` hook re-bootstraps after UniFi OS updates
- **Lightweight**: ~11 MB RSS total, ~8% of one CPU core for 3 cameras

> This project is built and maintained independently in spare time. If it saves you from wiring up Home Assistant automations or dealing with the terrible default patrol mode, [consider supporting it](https://ko-fi.com/H2H719VB0U).

## Prerequisites

Before installing, make sure the following are configured in UniFi Protect:

1. **Local user with admin role** — Create a dedicated local user (e.g. `patrol`) in UniFi OS Settings > Admins with the **Admin** role. This script uses local username/password authentication.

The script automatically handles these on startup (no manual action required):
- **Built-in patrols** — Stopped automatically if running (avoids conflicts)
- **Auto return home** — Disabled automatically if enabled (the script manages positioning itself)
- **Auto-tracking** — Disabled automatically when `dynamic_auto_tracking` is enabled (the script manages tracking dynamically)

## Installation

### One-Line Install

```bash
curl -sSL https://raw.githubusercontent.com/iceteaSA/unifi-ptz-better-patrol/main/install.sh | sudo bash
```

### With Credentials (skip manual config editing)

```bash
curl -sSL https://raw.githubusercontent.com/iceteaSA/unifi-ptz-better-patrol/main/install.sh \
  | sudo bash -s -- --nvr https://10.0.0.1 --username patrol --password secret
```

All three flags are optional — provide any combination. If `config.json` already exists, only the provided values are updated; everything else is preserved.

### Using a Different Branch

```bash
# Direct URL
curl -sSL https://raw.githubusercontent.com/iceteaSA/unifi-ptz-better-patrol/dev/install.sh | sudo bash

# Or via environment variable
PTZ_PATROL_BRANCH=dev curl -sSL https://raw.githubusercontent.com/iceteaSA/unifi-ptz-better-patrol/main/install.sh | sudo bash
```

### Manual Installation

If you prefer to inspect the code before installation:

```bash
git clone https://github.com/iceteaSA/unifi-ptz-better-patrol.git
cd unifi-ptz-better-patrol

# Run the installer (optionally with credentials)
sudo ./install.sh --nvr https://10.0.0.1 --username patrol --password secret
```

## Configuration

Edit `/data/ptz-patrol/config.json`:

```json
{
  "nvr_address": "https://127.0.0.1",
  "username": "api-user",
  "password": "changeme",
  "reauth_seconds": 3600,
  "auto_discover": true,
  "rediscovery_interval_seconds": 600,
  "log_level": "info",

  "defaults": {
    "dwell_seconds": 30,
    "motion_hold_seconds": 15,
    "max_tracking_wait": 300,
    "manual_control_hold_seconds": 120,
    "ptz_settle_seconds": 10,
    "home_on_shutdown": false,
    "home_between_cycles": false
  },

  "camera_overrides": {
    "YOUR_CAMERA_ID_HERE": {
      "enabled": true,
      "dwell_seconds": 45,
      "motion_hold_seconds": 20,
      "max_tracking_wait": 180,
      "manual_control_hold_seconds": 60,
      "preset_slots": [0, 1, 3]
    }
  }
}
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `nvr_address` | `https://127.0.0.1` | UniFi Protect NVR address |
| `username` | `api-user` | Local admin username |
| `password` | `changeme` | Local admin password |
| `reauth_seconds` | `3600` | Token refresh interval (seconds) |
| `auto_discover` | `true` | Auto-discover PTZ cameras on startup |
| `rediscovery_interval_seconds` | `600` | Re-discover cameras periodically (seconds); `0` to disable |
| `log_level` | `info` | Log verbosity: `error`, `warn`, `info`, `debug` |
| `defaults.dwell_seconds` | `30` | Time at each preset before advancing |
| `defaults.motion_hold_seconds` | `15` | Hold time after motion/smart detection |
| `defaults.max_tracking_wait` | `300` | Max seconds to wait during active tracking |
| `defaults.manual_control_hold_seconds` | `120` | Backoff time after manual PTZ control detected |
| `defaults.ptz_settle_seconds` | `10` | Grace period after a goto before checking for drift (auto-clamped to `dwell_seconds/2` at startup) |
| `defaults.home_on_shutdown` | `false` | Send cameras to home position on service stop |
| `defaults.home_between_cycles` | `false` | Go to home position after completing a full preset cycle before starting again |
| `defaults.dynamic_auto_tracking` | `false` | Enable dynamic auto-tracking (see below) |

### Per-Camera Overrides

Add entries under `camera_overrides` keyed by camera ID. Any field from `defaults` can be overridden. Set `"enabled": false` to skip a camera. Use `"preset_slots": [0, 1, 3]` to patrol specific presets instead of all discovered ones.

> **Tip**: Run `bash /data/ptz-patrol/discover.sh` to see all discovered cameras, their IDs, presets, zoom positions, and effective config.

Apply changes:
```bash
systemctl restart ptz-patrol.service
```

### Patrol Schedule

By default, patrol runs 24/7. Add a `schedule` block to restrict patrol to specific time windows. This can be set globally in `defaults` or per-camera in `camera_overrides`.

```json
{
  "defaults": {
    "schedule": {
      "start": "22:00",
      "end": "06:00",
      "days": ["mon", "tue", "wed", "thu", "fri"],
      "home_on_pause": true
    }
  }
}
```

| Field | Default | Description |
|-------|---------|-------------|
| `start` | — | Start time in 24h format (`"HH:MM"`). Required to enable schedule. |
| `end` | — | End time in 24h format (`"HH:MM"`). Required to enable schedule. |
| `days` | all days | Array of 3-letter day names: `"mon"`, `"tue"`, `"wed"`, `"thu"`, `"fri"`, `"sat"`, `"sun"` |
| `home_on_pause` | `false` | Send camera to home position when patrol pauses outside the schedule window |

Overnight windows work correctly — `"start": "22:00", "end": "06:00"` means patrol is active from 10 PM to 6 AM. Times use the system clock of the device (not UTC) — check with `date` on your NVR to verify the timezone.

If no `schedule` is set (or set to `null`), patrol runs continuously. Per-camera schedules override the global default:

```json
{
  "defaults": {
    "schedule": null
  },
  "camera_overrides": {
    "CAMERA_ID": {
      "schedule": {
        "start": "20:00",
        "end": "07:00",
        "home_on_pause": true
      }
    }
  }
}
```

### Dynamic Auto-Tracking

UniFi Protect suppresses motion events when auto-tracking is enabled (the camera is moving, so there's no relative motion in the frame). This creates a problem: you can't have both motion-aware patrol and auto-tracking at the same time.

Dynamic auto-tracking solves this by enabling auto-tracking **once at patrol start** and leaving it on permanently. The camera is always ready to track a person at any preset — no per-preset API toggling, minimal overhead. Tracking is only disabled on schedule pause and shutdown.

```json
{
  "defaults": {
    "dynamic_auto_tracking": true
  }
}
```

| Field | Default | Description |
|-------|---------|-------------|
| `dynamic_auto_tracking` | `false` | Enable dynamic auto-tracking (person detection only) |

When enabled, the script will:
1. Disable any existing auto-tracking on the camera at startup (clean slate)
2. Enable auto-tracking once before the patrol loop begins — camera is always ready to track
3. If the camera tracks a target, patrol holds until detection clears, then advances to the **next** preset (not back to the one the camera tracked away from)
4. PTZ drift detection is suppressed while tracking is enabled (camera movement from tracking is not external control)
5. Disable auto-tracking on schedule pause (re-enable on resume) and shutdown

This is per-camera configurable — you can enable it on specific cameras via `camera_overrides`.

### Log Levels

| Level | Shows | Use case |
|-------|-------|----------|
| `error` | Errors only (auth failures, missing presets, fatal conditions) | Production — minimal output |
| `warn` | Errors + warnings (retries, backoff, unexpected HTTP codes) | Production — recommended minimum |
| `info` | Normal operations (goto, hold, resume, discovery) | **Default** — day-to-day monitoring |
| `debug` | Everything (retry details, hold countdowns, motion clear) | Troubleshooting only |

Log format: `[timestamp] [LEVEL] [tag] message`
```log
[2026-03-10 12:00:00] [ERROR] [api] Auth failed
[2026-03-10 12:00:10] [WARN] [api] Auth attempt 1/5 failed — retrying in 10s
[2026-03-10 12:00:20] [INFO] [api] Authenticated
[2026-03-10 12:00:20] [DEBUG] [api] GET /cameras returned HTTP 200 (attempt 1/3)
```

## Operational Overview

### Patrol Loop (per camera)

```
┌──────────────────────┐
│  Check auth token    │ <-- refreshes automatically
└──────────┬───────────┘
           │
     ┌─────▼──────┐
     │  Schedule  │──outside──> Pause (optional go-home)
     │  active?   │             Re-check every 60s
     └─────┬──────┘
           │ yes
     ┌─────▼──────┐
     │ Failures > │──yes──> Exponential backoff
     │ threshold? │
     └─────┬──────┘
           │ no
     ┌─────▼──────┐
     │  External  │──yes──> Hold for manual_control_hold_seconds
     │  control?  │         (PTZ position drift detection)
     └─────┬──────┘
           │ no
     ┌─────▼──────┐
     │  Tracking  │──yes──> Hold (check every 5s, up to max_wait)
     │  active?   │         (advance to next preset when clear)
     └─────┬──────┘
           │ no
     ┌─────▼──────┐
     │  Go to     │ --> Records timestamp
     │  preset    │ --> Handles HTTP errors (retry, re-auth)
     └─────┬──────┘
           │
     ┌─────▼──────────────────────────────┐
     │  Dwell (adaptive poll interval)   │ <-- NOT a blind sleep
     │  ├─ Settle window: ignore motor-  │
     │  │  induced motion after goto     │
     │  ├─ Check PTZ position drift      │──> Hold if external control
     │  │  (pan/tilt/zoom vs expected)   │    (skipped when tracking)
     │  └─ Check motion/tracking         │──> Hold if activity detected
     │                                   │    (back to tracking check)
     └─────┬──────────────────────────────┘
           │
     next preset ──> (loop)
```

### Manual Control Detection

The Protect API doesn't expose a "camera is being controlled" flag. Detection uses full PTZ position comparison via the `/cameras/{id}/ptz/position` endpoint, which returns live pan, tilt, and zoom values in motor steps — the same coordinate system used by preset definitions.

**How it works:**

1. After each `goto`, the patrol waits for the settle window (`ptz_settle_seconds`) to let the motor reach its target. Motor-induced motion during this window is filtered out to prevent false triggers.
2. During the dwell period, the patrol polls at adaptive intervals (`min(5, dwell/3)` seconds, 2s floor) and compares the live pan/tilt/zoom position against the expected preset values.
3. If any axis drifts beyond the threshold (pan: 200 steps, tilt: 200 steps, zoom: 30 steps), manual control is detected.
4. The patrol enters a hold state for `manual_control_hold_seconds` before resuming.
5. For the home position (which has no preset data), the live position is sampled after the settle window as the baseline.

This catches manual control on **all three axes** — pan, tilt, and zoom — including control from the Protect app, which doesn't trigger `isMotionDetected` for pan/tilt moves. No additional hardware or Home Assistant integration required.

### Detection Hierarchy

The patrol hold checks these signals in priority order:
1. **External control** — pan/tilt/zoom drift from expected preset position
2. **Auto-tracking flag** (`isAutoTracking`, `isPtzAutoTracking`, `isTracking`) — firmware-dependent, may not exist
3. **Smart detection** (`isSmartDetected`) — real-time boolean; true when person, vehicle, animal, etc. is actively detected. Sets the internal `_LAST_SMART_ACTIVE` flag used by dynamic auto-tracking
4. **Motion detection** (`isMotionDetected`) — real-time boolean for active motion; also catches pan/tilt manual control during dwell
5. **Motion timestamp fallback** (`lastMotion`) — covers the hold window tail after `isMotionDetected` clears

### Error Resilience

- **API retry**: All HTTP calls retry up to 3 times with re-auth on 401/403
- **Exponential backoff**: After 3+ consecutive failures, backs off 10s->20s->40s->...->120s
- **Per-camera restart**: If a patrol loop crashes, it restarts after 10 seconds
- **No-preset backoff**: Cameras with fewer than 2 presets re-check every 5 minutes instead of spamming retries
- **Auth retry on startup**: Retries up to 5 times with backoff (NVR may still be booting)
- **Camera disconnect handling**: Treats disconnected cameras as "active" (fail-safe hold)
- **Process isolation**: Each camera has its own cookie jar and auth token (no shared state)

#### Power-outage field report

In a production four-camera UNVR deployment reported on 2026-08-09, a site-wide power outage left the NVR running on UPS while all four cameras were down for about 2.5 hours. Every patrol loop held position through the camera-disconnected fail-safe path. The surrounding journal contains zero `Patrol loop exited — restarting in 10s` entries across about 14 hours, all four camera subshells kept their original PIDs, and patrol resumed without operator action when camera power returned.

The journal has a gap during the outage because of the journald fault described below. This is a field report, not a lab result: the evidence for the outage window is the surviving process table and the surrounding hours of logs, not a continuous record.

## Resource Usage

The original three-camera figures below came from a UNVR with 30s dwell and 5s polling; the measurement date and hardware architecture were not recorded. The four-camera figures came from a live UNVR (aarch64, Debian 11) measured on 2026-08-09 at 15:25 SAST with `dwell_seconds=20`, `home_between_cycles=true`, and `dynamic_auto_tracking=true`.

| Resource | 3-camera baseline | 4-camera field measurement | Notes |
|----------|-------------------|--------------------------|-------|
| **Memory** | ~11 MB total | Not measured | The baseline is ~3 MB per process (1 main + 1 per camera). |
| **CPU** | ~8% of one core | 9.3% of one core | The field measurement was `CPUUsageNSec = 129022000000` over a 1387s active window. An independent ~16.5-hour lifetime average on the same deployment also measured 9.3%, including the camera outage; that is a coarse average with no measurable increase during fail-safe holding, not a controlled comparison. |
| **Processes** | 4 bash | 6 processes | The field deployment showed 1 main process + 4 camera subshells + 1 `sleep` for rediscovery. |
| **Temp files** | 12 | Not measured | 3 per process in the baseline (cookie, headers, body); cleaned on exit. |
| **File descriptors** | 3-4 per process | Not measured | Minimal; no long-lived connections. |

## Monitoring & Logging

Key operational signals:

```log
# Discovery
[2026-03-10 12:00:00] [INFO] [main] Discovering PTZ cameras...
[2026-03-10 12:00:01] [INFO] [main] Found 3 PTZ camera(s) — launching patrol loops

# Normal patrol
[2026-03-10 12:00:02] [INFO] [Front Door] Patrol: presets=[0 1 2 3] dwell=30s hold=15s max_wait=300s manual_hold=120s
[2026-03-10 12:00:32] [INFO] [Front Door] → Slot 1 [HTTP 200]

# PTZ manual control detection (any axis — pan, tilt, or zoom)
[2026-03-10 12:02:00] [WARN] [Front Door] PTZ drift: pan=22200/18500 tilt=9400/9400 zoom=873/873
[2026-03-10 12:02:00] [WARN] [Front Door] External control detected — holding patrol for 120s
[2026-03-10 12:04:00] [INFO] [Front Door] Manual control hold expired — resuming patrol

# Motion during dwell
[2026-03-10 12:05:02] [INFO] [Gate PTZ] Activity during dwell — holding
[2026-03-10 12:05:02] [INFO] [Gate PTZ] Tracking/motion active — holding

# Camera with no presets configured
[2026-03-10 12:00:03] [WARN] [Back Yard] Only 0 preset(s) — need 2+. Skipping.
[2026-03-10 12:00:03] [WARN] [Back Yard] No presets — will re-check in 5 minutes

# Error recovery
[2026-03-10 12:10:00] [WARN] [api] Auth error on GET /cameras/abc123 (HTTP 401) — re-authenticating
[2026-03-10 12:10:00] [WARN] [Driveway] 3 consecutive failures — backing off 20s
[2026-03-10 12:10:20] [WARN] [Driveway] Patrol loop exited — restarting in 10s

# Dynamic auto-tracking (enabled once at start, always ready to track)
[2026-03-10 12:00:02] [INFO] [Driveway] Auto-tracking enabled (["person"])
[2026-03-10 12:00:02] [INFO] [Driveway] → Slot 0 [HTTP 200]
[2026-03-10 12:10:05] [INFO] [Driveway] Activity during dwell — holding
[2026-03-10 12:10:05] [INFO] [Driveway] Tracking/motion active — holding
[2026-03-10 12:11:05] [DEBUG] [Driveway] Clear after 65s — resuming
[2026-03-10 12:11:05] [INFO] [Driveway] → Slot 4 [HTTP 200]

# Auto-setup on startup
[2026-03-10 12:00:01] [INFO] [main] Front Door: disabled auto-tracking for dynamic mode (was ["person"])
[2026-03-10 12:00:01] [INFO] [main] Front Door: stopped built-in patrol (was slot 0)

# Schedule pause/resume
[2026-03-10 06:00:01] [INFO] [Front Door] Outside schedule window (22:00-06:00) — pausing patrol
[2026-03-10 06:00:01] [INFO] [Front Door] Sent to home position
[2026-03-10 22:00:01] [INFO] [Front Door] Schedule window active (22:00-06:00) — resuming patrol

# Graceful shutdown
[2026-03-10 13:00:00] [INFO] [main] Shutdown requested — stopping all patrols
[2026-03-10 13:00:00] [INFO] [main] Disabling dynamic auto-tracking...
[2026-03-10 13:00:00] [INFO] [main] Sending cameras to home position...
[2026-03-10 13:00:01] [INFO] [main] Shutdown complete
```

View logs with:
```bash
journalctl -u ptz-patrol.service -f                        # Live monitoring
journalctl -u ptz-patrol.service --since "10 minutes ago"  # Recent history
journalctl -u ptz-patrol.service -p warning                # Warnings and errors only
```

## Troubleshooting

### The service looks dead but is still running

**Symptom:** `journalctl -u ptz-patrol` produces no output, while `systemctl status ptz-patrol` shows an active service with a live MainPID. The per-camera subshells are also alive in `ps --ppid <MainPID>`. Restarting `ptz-patrol` does not restore logging, including the startup banner.

This was reported from a live UNVR deployment. The cause was a wedged journald stdout-stream listener. systemd gives the service a socket connected to journald; when that listener breaks, the service's socket is connected to nothing. Restarting the service gets another socket from the same broken listener, so the symptom remains. The patrol loops keep running normally, but writes to the dead socket fail silently. Logs from the wedged window are discarded, not buffered, and cannot be recovered.

A power event and a corrupted rotated journal file from an earlier boot were contributing factors in the reported case. NVRs often stay up on a UPS while their journals take corruption during a power event.

Test the service's stdout socket directly, replacing `<MainPID>` with the PID from `systemctl status`:

```bash
echo test > /proc/<MainPID>/fd/1
```

`No such device or address` confirms that the socket has no peer. Restart journald, then the patrol service:

```bash
systemctl restart systemd-journald && systemctl restart ptz-patrol
```

## Maintenance

```bash
# Service Management
systemctl status ptz-patrol.service    # Current state
systemctl restart ptz-patrol.service   # Apply config changes

# Discovery (see cameras, presets, zoom, effective config)
bash /data/ptz-patrol/discover.sh

# Full Removal
/data/ptz-patrol/uninstall.sh
```

## Project Structure

- **ptz-patrol.sh**: Main entrypoint — discovers cameras and launches parallel patrol loops with per-process isolation and graceful shutdown
- **api.sh**: Shared library for auth, HTTP with retry, config caching, motion/tracking detection, PTZ position queries, and log level filtering
- **discover.sh**: PTZ camera discovery and config dump (dual-mode: sourceable + standalone). Fetches presets from the per-camera `/ptz/preset` endpoint (the `ptzPresetPositions` field on camera objects is empty on many firmware versions)
- **patrol.sh**: Core per-camera patrol loop with manual control detection, active dwell monitoring, and error resilience
- **config.json.example**: Example configuration template (copied to `config.json` on install)
- **install.sh**: Installation script with optional `--nvr`, `--username`, `--password` flags
  - Supports installation from different branches via the `PTZ_PATROL_BRANCH` environment variable
  - Automatically downloads required files if not found locally
- **uninstall.sh**: Script to remove the patrol system
- **ptz-patrol.service**: Systemd service configuration

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

**Compatibility**: Verified on UniFi OS 4.0.0+ with G5 PTZ and G6 PTZ cameras.
**License**: MIT

### Keywords

unifi, unifi-protect, ptz, ptz-patrol, ptz-tour, pan-tilt-zoom, g5-ptz, g6-ptz, ubiquiti, udm, udr, unvr, camera-patrol, preset-tour, motion-aware, auto-tracking, home-assistant-alternative, bash, systemd, unifi-os
