# UniFi PTZ Better Patrol

[![CI](https://github.com/iceteaSA/unifi-ptz-better-patrol/actions/workflows/ci.yml/badge.svg)](https://github.com/iceteaSA/unifi-ptz-better-patrol/actions/workflows/ci.yml)

Motion-aware PTZ camera patrol system for Ubiquiti UniFi Protect devices running UniFi OS.

Confirmed working on: UDM, UDR, UNVR, UNVR Pro (any device running UniFi Protect with PTZ cameras)

Tested with: **G5 PTZ**, **G6 PTZ**, and **AI PTZ Industrial** cameras only. Other UniFi PTZ models may work but are untested.

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
- **Per-Preset Dwell and Path Mode**: Set a dwell time for each preset, and patrol the presets in a loop or back and forth (`pingpong`)
- **Fixed-Camera Cues**: A smart detection on a fixed camera sends an idle PTZ to a mapped preset. Cues can filter by object type and smart zone. When the PTZ loses a track, a cue can send it to where a fixed camera sees the subject now
- **HomeView Handling**: When Protect sends the camera back to its HomeView, patrol does not treat the move as manual control
- **Home Assistant Status**: An optional webhook posts the patrol state of each camera and a periodic heartbeat
- **Optional Patrol Schedule**: Restrict patrol to specific time windows and days of the week, with optional "go home" when paused
- **Parallel Patrol Loops**: Each camera runs its own independent patrol process with isolated auth
- **Configurable Log Levels**: Control verbosity with `error`, `warn`, `info`, or `debug`
- **Hold Limits**: `max_tracking_wait` limits holds for motion only, and `max_smart_wait` limits holds for smart detection or tracking (`0` removes that limit)
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

### Security

The installer is the trust root. It is fetched from GitHub over HTTPS with certificate validation, then downloads the files systemd will run as root. Read `install.sh` before piping it to `bash` if you want to verify what it does. Remote installs resolve the selected branch to a commit before downloading. Every file then comes from that commit. If GitHub's API cannot resolve the branch, the installer prints a warning and falls back to the branch URL. Local-checkout installs record the checkout's commit when Git is available.

The installer writes `/data/ptz-patrol/install-info` with `ref`, `commit`, and UTC `installed_at` values. The daemon logs its version and commit at startup, for example `ptz-patrol 1.7.0 (main@33e810b) starting`. The `discover.sh` output header prints the same version string. Bootstrap does not change this metadata.

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
    "max_smart_wait": 1800,
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
      "max_smart_wait": 1800,
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
| `status_webhook_url` | `""` | Optional HTTP or HTTPS URL for status posts. The URL is a secret. |
| `defaults.dwell_seconds` | `30` | Time at each preset before advancing |
| `defaults.preset_dwell_seconds` | `{}` | Dwell seconds for each slot. Other slots use `dwell_seconds`. |
| `defaults.path_mode` | `"loop"` | `"loop"` uses the preset list again. `"pingpong"` uses the inner slots in the opposite order before the next cycle. |
| `defaults.motion_hold_seconds` | `15` | Hold time after motion/smart detection |
| `defaults.max_tracking_wait` | `300` | Motion-only hold seconds before patrol advances. Smart detection or tracking sets this counter to zero. Unreadable polls pause it. |
| `defaults.max_smart_wait` | `1800` | Total activity-hold seconds before patrol advances while smart detection or tracking is active. Use an integer ≥ 0. `0` disables this cap. Invalid values give a warning and use `1800`. |
| `defaults.manual_control_hold_seconds` | `120` | Backoff time after manual PTZ control detected |
| `defaults.ptz_settle_seconds` | `10` | Grace period after a goto before checking for drift (auto-clamped to `dwell_seconds/2` at startup) |
| `defaults.home_on_shutdown` | `false` | Send cameras to home position on service stop |
| `defaults.home_between_cycles` | `false` | Go to home position after completing a full preset cycle before starting again |
| `defaults.dynamic_auto_tracking` | `false` | Enable dynamic auto-tracking (see below) |
| `defaults.auto_tracking_object_types` | `["person"]` | Object types for dynamic auto-tracking. `vehicle` is available only on compatible cameras. |
| `defaults.auto_tracking_with_zoom` | `null` | `true` or `false` sets zoom when auto-tracking starts. `null` keeps the camera setting. |
| `defaults.status_heartbeat_seconds` | `300` | Seconds between status reports. Use an integer with a minimum of `30`, or `0` for state changes only. |

### Per-Camera Overrides

Activity holds check the camera at 5-second intervals. Smart detection and tracking do not use the motion-only cap. `max_smart_wait` prevents a smart flag that stays on from stopping patrol without an end. Each hold-end log gives the total time and seconds for tracking, smart detection, and motion. The log includes unknown seconds only when non-zero. Each interval counts for the reason from the poll before it.

When tracking ends, patrol immediately logs its pan, tilt and zoom, or `Tracking ended (position unreadable)` if it cannot read the position.

Add entries under `camera_overrides` keyed by camera ID. Any field from `defaults` can be overridden. Set `"enabled": false` to skip a camera. Use `"preset_slots": [0, 1, 3]` to patrol specific presets instead of all discovered ones.

Set `preset_dwell_seconds` in `defaults` or a camera override. Each key is a preset slot string. Each value must be a positive integer, or a string of digits for that integer. Patrol logs a warning and ignores invalid entries and slots not in the patrol list.

For example, `{"4": 45, "2": 15}` sets 45 seconds for slot 4 and 15 seconds for slot 2.

For each slot, the settle window uses `ptz_settle_seconds`. Its maximum is half that slot's dwell (minimum 1 second). The poll interval is one third of that dwell. Its minimum is 2 seconds and its maximum is 5 seconds. Home-between-cycles uses the camera's `dwell_seconds`, settle window, and poll interval.

Protect can send the camera to its HomeView after auto-tracking. For each drift check after target acquisition, patrol reads `/cameras/{id}/ptz/home` one time. The maximum difference from HomeView is 200 pan/tilt steps and 30 zoom steps. This maximum applies to each axis.

Before a failed-goto retry, patrol checks this PTZ's smart events from the last 30 seconds. An open event, or one that ended in the last 10 seconds, holds patrol instead of pulling the camera off its subject. All event types count, including face-only events with no active zone. The status is `holding_activity`. Patrol checks again at each poll and limits the hold with `max_smart_wait` (`0` has no limit).

Patrol logs `Goto target not acquired — own smart event (<types>) open; holding instead of re-issuing` once for the hold. When the event clears or the hold reaches its limit, the usual bounded goto retries continue. An event request or parse error logs one warning and keeps the previous retry behaviour. Polls without a pending retry make no extra request.

Patrol then skips the manual-control hold and stops position checks until the next goto. If patrol cannot read HomeView, or its data is invalid, the usual drift rules apply. Patrol also skips this hold when you push Home in the Protect app: it counts as camera-initiated movement.

If a manual-control hold starts while the camera is still away from HomeView, patrol keeps the HomeView coordinates from that drift check. During the hold, it reads the position every 5 seconds if those coordinates are known. Two consecutive reads within the same per-axis limits end the hold early. Patrol logs `Camera returned to its HomeView — ending manual hold` and clears the old target before normal checks resume. A failed or invalid position read resets the count and keeps the hold. An unknown HomeView keeps the full hold, with no position reads during it. This rule handles short auto-tracking starts that Protect returns to HomeView after its tracking timeout, even without a confirmed smart detection. A manual joystick move does not cause that return. If you push Home in the Protect app during a hold, the hold also ends after about 10 seconds. Move the camera again to start a new hold.

Set `path_mode` to `"pingpong"` in `defaults` or a camera override to use the two directions. For example, `[0, 1, 2, 3]` becomes `[0, 1, 2, 3, 2, 1]`. The path does not duplicate its endpoints. Two slots keep their initial order. Other values log a warning and use `"loop"`.

With `home_between_cycles`, the camera goes home after it completes the full path, before the next cycle starts.

> **Tip**: Run `bash /data/ptz-patrol/discover.sh` to see all discovered cameras, their IDs, presets, zoom positions, and effective config.

Apply changes:
```bash
systemctl restart ptz-patrol.service
```

### Fixed-Camera Cues

Set `camera_overrides.<ptz id>.cues` to send a PTZ to a preset when a fixed camera detects a smart type:

```json
"cues": [
  {"camera_id": "FIXEDCAMERAID", "slot": 0, "types": ["person"], "hold_seconds": 30, "cooldown_seconds": 120}
]
```

| Cue key | Default | Requirement |
|---------|---------|-------------|
| `camera_id` | Necessary | The fixed camera id, not this PTZ's id. Use 1-64 ASCII letters or digits. |
| `slot` | Necessary | An integer slot in this PTZ's presets. A slot is permitted if `preset_slots` does not contain it. |
| `types` | `["person"]` | A non-empty array of non-empty strings. Patrol removes duplicates. |
| `zones` | No filter | A non-empty array of zone names, non-negative integer ids, or strings of digits. |
| `hold_seconds` | `30` | An integer with a minimum of 5 seconds. |
| `cooldown_seconds` | `120` | An integer with a minimum of 0 seconds, for each cue entry. |

Patrol checks entries one time at startup. It drops each invalid entry with one warning. It reads each source camera's Protect name one time. If patrol cannot read the name, it uses the id and logs a warning. Discovery shows the names and marks unknown camera ids.

With `zones`, an event must list at least one of the cue's zones with a status other than `none`, and one of its types. Patrol resolves zones at startup from the source camera's `smartDetectZones`. An exact name match comes first, then an id match. If a zone does not resolve, patrol logs `Cue zone "<zone>" not found on <source> — ignoring this cue entry` and drops only that entry.

Zone ids stay usable if the startup camera read fails. Zone names do not. If the read succeeds, the id must exist on that camera. Discovery shows zone names and marks unknown zones.

The cue log names the matched zone, for example `Cue: Path Cam person (Far side) → slot 0`. If no name is known, it shows the zone id. An entry without zones keeps the log without a zone name.

Patrol checks cues at preset, home, and cue dwell polls, after activity and manual-control checks. Normal cue checks stop during activity, tracking, manual holds, schedule pauses, and unreadable camera state. Current zone presence wins, then config order. Each entry has its own cooldown, which starts when that entry fires.

A cue for the current commanded slot logs `(already there)` and starts a cue hold without a goto. It marks the event seen and starts the entry's cooldown. During a cue hold at that slot, it starts the hold timer again with the new entry's `hold_seconds`. Re-acquire cues still send a goto because tracking moved the camera. Home dwell has no commanded preset slot, so a home-dwell cue also sends a goto.

The entry's cooldown limits these timer restarts. With the default 120 seconds, an entry can restart a hold at most once in 120 seconds. With `cooldown_seconds: 0`, new events from the source can keep the slot on hold. The same event cannot restart that entry's hold again.

A cue for a different slot ends a cue hold early. Its log adds `(pre-empts <previous cue name>)`. The status stays `cued`, with the new source in `cue_camera`. After the last cue hold, patrol resumes the path step selected before the first cue. A new cue does not apply the half-dwell rule again to that step.

After a track is lost, cues can end the activity hold and re-acquire the subject. Once an activity hold has had a tracking poll, each later poll can check cues. The PTZ must be readable, must not track, and must have no active smart detection.

This includes the poll that ends the hold. These checks use the usual poll interval, with no additional sleep. Holds that never had tracking do not check cues.

Every cue poll reads events that started in the last 120 seconds:

- For an event older than 15 seconds, a configured zone must show `enter` or `moving`. Protect changes this status to `leave` 0-9 seconds after the subject leaves the zone.
- Without a zone filter, any event zone with `enter` or `moving` is sufficient.
- An event from the last 15 seconds can also match the status-other-than-`none` rule.
- A match with `enter` or `moving` has priority over a match with another status. Config order breaks ties.

A hit logs `Tracking lost — Cue: <name> <type> (<zone name>) → slot N`. It then uses the usual cue goto, hold, status, and resume path.

The cue uses the usual goto, target acquisition, retry, drift, and HomeView checks. It uses `hold_seconds` for the dwell. The PTZ's own activity can extend that dwell through the usual hold. Motion-only time uses `max_tracking_wait`. Smart detection or tracking uses `max_smart_wait`. Unknown activity stays on hold without a cap.

If a cue stops a path step before half of that slot's dwell time, patrol repeats the step after the cue. Cues can cause only one repeat per path step. A second early cue counts that step as complete. The limit also applies with `cooldown_seconds: 0`. When the path advances, the next step can repeat one time. At half of the dwell time or more, patrol uses the next path step. This also applies on a `pingpong` path. If that advance ends a cycle, patrol skips that cycle's home visit. A cue from a home dwell resumes at the first path step, or the second if the cue held the first step's slot.

When a cue hold ends, patrol logs `Cue hold ended`. Activity or manual control can keep patrol on hold after this line. If the next normal path step is the cue slot, patrol skips that one step. It logs `Skipping slot N — the cue just held it` at debug level. This skip does not visit home on a cycle wrap. It applies to completed and interrupted cue holds, exhausted goto retries, and rejected cue commands.

Patrol sends the cue goto one time. The usual bounded goto retries can send that command again. Dynamic tracking does not cause an additional path-step skip after a cue.

Before the cue goto, patrol checks the time since the cue match. After more than 15 seconds, patrol drops the cue. This also applies after a schedule pause, manual hold, activity hold, or unreadable camera state. It logs `Cue dropped — <age>s old` and uses the path step selected by the half-dwell rule. Dynamic tracking does not skip that step.

If a pre-empting cue expires before its goto, the previous cue hold also ends. Patrol clears its cue status and resumes the selected path step. The previous hold cannot supply the dwell time or source name for that path step.

An event can become available while cue checks are off. It can fire when checks start again within the 120-second start window, if its zone status matches the rules above. Protect lists new events about 3 seconds after their start. Patrol ignores the event's `end` field: a null value does not prove that the subject is present.

Each cue entry can fire only once per event. Another entry can fire on the same event later, for example when the subject moves to another zone. Patrol reads event types and zone status again at each poll. This also applies when an entry is in cooldown. Fired entries stay in the seen map until their event start is older than 120 seconds.

Missing or empty `cues` adds no poll or goto processes and no HTTP requests. An empty event poll starts one curl and no jq. An event request error gives no cue and does not stop patrol.

The first event request error logs one warning with the HTTP code and curl exit code. This includes a JSON parse error. More errors give no new warning until an event request succeeds. That success logs `Cue poll recovered`, also for an empty `[]` response. Usual empty polls give no log line.

At debug level, `Cue skip` lines give the entry, short event id, event types, and a zone snapshot as `id:status` pairs. The reasons are `cooldown`, `seen`, `camera`, `type`, `zone`, and `window` (too old without current presence, or outside the 120-second window). `Cue fired` gives the same snapshot for a match. Info level adds no lines or jq processes for these diagnostics.

### Patrol Schedule

By default, patrol runs 24/7. Add a `schedule` block to restrict patrol to specific time windows. This can be set globally in `defaults` or per-camera in `camera_overrides`.

```json
{
  "defaults": {
    "schedule": {
      "start": "22:00",
      "end": "06:00",
      "days": ["mon", "tue", "wed", "thu", "fri"],
      "constrain_start_minute": 15,
      "constrain_end_minute": 45,
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
| `constrain_start_minute` | — | Optional numeric start minute (`0`-`59`) for the constrained patrol period. |
| `constrain_end_minute` | — | Optional numeric end minute (`0`-`59`) for the constrained patrol period. |
| `home_on_pause` | `false` | Send camera to home position when patrol pauses outside the schedule window |

Overnight windows work correctly — `"start": "22:00", "end": "06:00"` means patrol is active from 10 PM to 6 AM. Times use the system clock of the device (not UTC) — check with `date` on your NVR to verify the timezone.

The optional minute constraint uses the device clock, like the schedule. Patrol runs only when both windows are active. The example uses `15` to `45`. Patrol runs during minutes 15-44 of each hour inside the schedule. A same-hour window from `15` to `45` includes minute 15 and excludes minute 45. A cross-hour window from `45` to `15` includes minutes 45-59 and 0-14.

The windows intersect at schedule edges. For example, schedule `22:00`-`06:00` with `45` to `15` is active at 22:00-22:14 and 22:45-23:14. It continues each hour through 05:45-05:59.

If a hold is active when a window ends, it finishes first. Motion-only time uses `max_tracking_wait`. Smart detection or tracking uses the total hold-time cap `max_smart_wait`; `0` permits an unlimited smart hold. Unknown activity stays on hold without a cap. The next schedule check then pauses patrol. An invalid, incomplete, or equal minute pair logs a warning. Patrol runs without the constraint.

The schedule-pause actions also apply at each constrained-window end. If `home_on_pause` is `true`, the camera goes home at each end, including hourly ends inside the schedule. If `dynamic_auto_tracking` is `true`, auto-tracking turns off at each window end and on again when the next window starts.

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
| `dynamic_auto_tracking` | `false` | Enable dynamic auto-tracking |

Set `auto_tracking_object_types` to `["person","vehicle"]` for person and vehicle detection on a compatible camera, such as the AI PTZ Industrial. Patrol always accepts `person` as a type. Patrol checks the types at startup. It logs a warning for each unknown or unsupported type and removes it. A non-array or an empty result logs a warning and uses `["person"]`.

Set `auto_tracking_with_zoom` to `true` or `false` to change the camera setting in the same enable request. Do not set it, or use `null`, to keep the camera setting. Pause and shutdown disable auto-tracking without a zoom change. The two keys can use camera overrides.

When enabled, the script will:
1. Disable any existing auto-tracking on the camera at startup (clean slate)
2. Enable auto-tracking once before the patrol loop begins — camera is always ready to track
3. If the camera tracks a target, patrol holds until detection clears, then advances to the **next** preset (not back to the one the camera tracked away from)
4. PTZ drift detection is suppressed while tracking is enabled (camera movement from tracking is not external control)
5. Disable auto-tracking on schedule pause (re-enable on resume) and shutdown

This is per-camera configurable — you can enable it on specific cameras via `camera_overrides`.

### Home Assistant

Set the top-level `status_webhook_url` to a Home Assistant webhook URL. For example:

```json
{
  "status_webhook_url": "https://homeassistant.example/api/webhook/REPLACE_WITH_RANDOM_ID",
  "defaults": {
    "status_heartbeat_seconds": 300
  }
}
```

The URL is a secret. Do not put it in logs, screenshots, or public reports. Use an empty string to disable posts. Patrol accepts only HTTP and HTTPS URLs. It rejects double-quote characters, backslashes, whitespace, and control characters.

Use `https://` with a certificate that the NVR trusts. An `http://` URL sends the webhook id unencrypted on a LAN. A device that can read that traffic can copy the id and send incorrect status reports. Patrol logs this risk without the URL. The service removes proxy settings from its environment to prevent a proxy from receiving the webhook id or NVR traffic. Each install or update sets `config.json` to mode `0600` because it holds the NVR password and webhook URL.

Patrol posts on each state change. A heartbeat sends the current state again after `status_heartbeat_seconds`. Camera overrides can set this interval. Use an integer with a minimum of 30 seconds, or `0` to disable heartbeats.

Reports follow the poll interval. Schedule pauses check at 60-second intervals. Use the default 300-second heartbeat for the notification example below.

Each background request has a five-second limit and no retry. A post error is silent. A slow webhook does not stop patrol. Shutdown sends `stopped` for all patrolled cameras in parallel and waits for those requests before exit.

The JSON payload has these fields:

```json
{
  "camera_id": "YOUR_CAMERA_ID",
  "camera": "Gate",
  "state": "patrolling",
  "slot": 4,
  "since": 1794513600,
  "ts": 1794513900,
  "version": "1.7.0 (main@33e810b)",
  "cue_camera": null
}
```

`since` and `ts` are Unix times in seconds, not milliseconds and not ISO text. In Home Assistant, `as_datetime` reads them directly. `since` is the time when the state started, and `ts` is the time of the post. A heartbeat keeps `since` unchanged.

`slot` is the last commanded slot. The first post after a start can come before the first preset command, so its `slot` is `null`. This value does not mean that the camera has no presets. Home uses slot `-1`. Shutdown uses `null` and sets `since` to the shutdown time.

| Payload field | Value |
|---------------|-------|
| `camera_id` | PTZ camera id. |
| `camera` | PTZ display name. |
| `state` | One of the states below. |
| `slot` | Last commanded slot, or `null` if unknown. |
| `since` | State start time in Unix seconds. |
| `ts` | Post time in Unix seconds. |
| `version` | Installed version and ref. |
| `cue_camera` | Source Protect name in `cued`, or JSON `null` in other states. An unsuccessful name read uses the source id. |

| State | Meaning |
|-------|---------|
| `patrolling` | Patrol commands and dwell at a selected slot or home. |
| `cued` | Dwell at a cue slot. `cue_camera` identifies the fixed camera. Activity during this dwell reports `holding_activity`. |
| `holding_activity` | Movement or auto-tracking holds patrol. Temporary read errors also hold patrol. |
| `holding_manual` | Manual PTZ control holds patrol. |
| `paused_schedule` | The schedule has paused patrol. |
| `unreadable` | The five-minute camera-read warning has occurred. The state stays until `is_tracking` gets a correct `CONNECTED` camera response. |
| `stopped` | The daemon is shutting down. |

Minimum Home Assistant version: `2024.10`. The example uses the `triggers:` and `actions:` keys.

This Home Assistant YAML stores the last report and state for one camera. It makes a notification when it gets no report for 600 seconds, two times the default heartbeat. A check runs each minute. Home Assistant uses the notification id to update the same notification. Change the webhook id, camera id, and helper names for your camera. Do not use this missing-heartbeat notification with a heartbeat of `0`.

```yaml
input_datetime:
  ptz_gate_last_seen:
    name: PTZ Gate last report
    has_date: true
    has_time: true

input_text:
  ptz_gate_status:
    name: PTZ Gate status

automation:
  - alias: PTZ Gate status report
    triggers:
      - trigger: webhook
        webhook_id: REPLACE_WITH_RANDOM_ID
        allowed_methods: [POST]
        local_only: true
    conditions:
      - condition: template
        value_template: '{{ trigger.json.camera_id == "YOUR_CAMERA_ID" }}'
    actions:
      - action: input_datetime.set_datetime
        target:
          entity_id: input_datetime.ptz_gate_last_seen
        data:
          timestamp: '{{ now().timestamp() }}'
      - action: input_text.set_value
        target:
          entity_id: input_text.ptz_gate_status
        data:
          value: '{{ trigger.json.state }}'

  - alias: PTZ Gate missing heartbeat
    triggers:
      - trigger: time_pattern
        minutes: "/1"
    conditions:
      - condition: template
        value_template: >-
          {{ states('input_datetime.ptz_gate_last_seen') not in ['unknown', 'unavailable']
             and as_timestamp(now()) - as_timestamp(states('input_datetime.ptz_gate_last_seen'), 0) > 600 }}
    actions:
      - action: persistent_notification.create
        data:
          notification_id: ptz_gate_missing_heartbeat
          title: PTZ patrol not reporting
          message: Gate patrol has sent no status for twice its heartbeat interval.
```

### Log Levels

| Level | Shows | Use case |
|-------|-------|----------|
| `error` | Errors only (auth failures, missing presets, fatal conditions) | Production — minimal output |
| `warn` | Errors + warnings (retries, backoff, unexpected HTTP codes) | Production — recommended minimum |
| `info` | Normal operations (goto, hold, resume, discovery) | **Default** — day-to-day monitoring |
| `debug` | Everything (retry details, hold countdowns, motion clear) | Troubleshooting only |

Log format: `[timestamp] [LEVEL] [tag] message`

The tag uses the camera name from Protect. Cameras with the same name add the last six camera ID characters: `Driveway #abc123`. The tag keeps this suffix after a name change. Each poll uses the name from the camera state response. A name change logs one info line, then subsequent lines use the new name. An empty or unreadable name does not change the tag.

```log
[2026-03-10 12:00:00] [ERROR] [api] Auth failed
[2026-03-10 12:00:10] [WARN] [api] Auth attempt 1/5 failed — retrying in 10s
[2026-03-10 12:00:20] [INFO] [api] Authenticated
[2026-03-10 12:00:20] [DEBUG] [api] GET /cameras returned HTTP 200 (attempt 1/3)
[2026-03-10 12:00:20] [INFO] [Driveway #abc123] Patrol: presets=[0 4 2] dwell=30s settle=10s poll=5s hold=15s max_wait=300s max_smart_wait=1800s manual_hold=120s preset_dwell=4:45,2:15
[2026-03-10 12:00:20] [INFO] [Garden] Patrol: presets=[0 1 2 3 2 1] dwell=30s settle=10s poll=5s hold=15s max_wait=300s max_smart_wait=1800s manual_hold=120s path=pingpong
[2026-03-10 12:00:25] [INFO] [Driveway #abc123] Camera renamed in Protect: 'Driveway' → 'Gate'
[2026-03-10 12:00:30] [INFO] [Gate #abc123] → Slot 4 [HTTP 200]
[2026-03-10 12:00:45] [INFO] [Gate #abc123] PTZ drift detected: pan(11127→10880) tilt(10412→11430) zoom(710→0)
[2026-03-10 12:00:45] [INFO] [Gate #abc123] Camera returned to its HomeView — not manual control
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
     │  Tracking  │──yes──> Hold (check every 5s; smart/motion caps)
     │  active?   │         (advance to next preset when clear;
     │            │          a cue can end the hold after a lost track)
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
     │  ├─ Check motion/tracking         │──> Hold if activity detected
     │  │                                │    (back to tracking check)
     │  └─ Check fixed-camera cues       │──> Go to the cue preset
     └─────┬──────────────────────────────┘
           │
     next preset ──> (loop)
```

### Manual Control Detection

The Protect API doesn't expose a "camera is being controlled" flag. Detection uses full PTZ position comparison via the `/cameras/{id}/ptz/position` endpoint, which returns live pan, tilt, and zoom values in motor steps — the same coordinate system used by preset definitions.

**How it works:**

1. After each `goto`, the patrol waits for the settle window (`ptz_settle_seconds`) to let the motor reach its target. Motor-induced motion during this window is filtered out to prevent false triggers.
2. During the dwell period, the patrol polls at adaptive intervals (`min(5, dwell/3)` seconds, 2s floor) and compares the live pan/tilt/zoom position against the expected preset values.
3. Patrol first checks two position reads at the target, one after the other. Then drift above a threshold starts a confirmation check (pan: 200 steps, tilt: 200 steps, zoom: 30 steps). A position at HomeView is not manual control. The camera completes its dwell without more position checks.
4. Other drift must continue for two polls before patrol starts a hold for `manual_control_hold_seconds`. If patrol cannot read HomeView, the same confirmation rule applies.
5. For the home position (which has no preset data), the live position is sampled after the settle window as the baseline.

This catches manual control on **all three axes** — pan, tilt, and zoom — including control from the Protect app, which doesn't trigger `isMotionDetected` for pan/tilt moves. No additional hardware or Home Assistant integration required.

### Detection Hierarchy

The patrol hold checks these signals in priority order:
1. **External control** — pan/tilt/zoom drift from expected preset position
2. **Tracking** — a smart detection (`isSmartDetected`) while the camera has auto-tracking object types (`smartDetectSettings.autoTrackingObjectTypes`). Patrol also reads the status flags `isAutoTracking`, `isPtzAutoTracking`, and `isTracking`, but the tested G5, G6, and AI PTZ firmware does not send them
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

The journal has a gap during the outage. The most likely cause is the log rate limit in versions before 1.6.1, described in Troubleshooting. This is a field report, not a lab result: the evidence for the outage window is the surviving process table and the surrounding hours of logs, not a continuous record.

## Resource Usage

The original three-camera figures below came from a UNVR with 30s dwell and 5s polling; the measurement date and hardware architecture were not recorded. The four-camera figures came from a live UNVR (aarch64, Debian 11) measured on 2026-08-09 at 15:25 SAST with `dwell_seconds=20`, `home_between_cycles=true`, and `dynamic_auto_tracking=true`.

| Resource | 3-camera baseline | 4-camera field measurement | Notes |
|----------|-------------------|--------------------------|-------|
| **Memory** | ~11 MB total | Not measured | The baseline is ~3 MB per process (1 main + 1 per camera). |
| **CPU** | ~8% of one core | 9.3% of one core | The field measurement was `CPUUsageNSec = 129022000000` over a 1387s active window. An independent ~16.5-hour lifetime average on the same deployment also measured 9.3%, including the camera outage; that is a coarse average with no measurable increase during fail-safe holding, not a controlled comparison. |
| **Processes** | 4 bash | 6 processes | The field deployment showed 1 main process + 4 camera subshells + 1 `sleep` for rediscovery. |
| **Temp files** | 12 | Not measured | 3 per process in the baseline (cookie, headers, body). From 1.6.1 there are 4 per process: the session headers have their own file. Patrol removes them on exit. |
| **File descriptors** | 3-4 per process | Not measured | Minimal; no long-lived connections. |

## Monitoring & Logging

Key operational signals:

```log
# Discovery
[2026-03-10 12:00:00] [INFO] [main] ptz-patrol 1.7.0 (main@33e810b) starting
[2026-03-10 12:00:00] [INFO] [main] Discovering PTZ cameras...
[2026-03-10 12:00:01] [INFO] [main] Found 3 PTZ camera(s) — launching patrol loops

# Normal patrol
[2026-03-10 12:00:02] [INFO] [Front Door] Patrol: presets=[0 1 2 3] dwell=30s settle=10s poll=5s hold=15s max_wait=300s max_smart_wait=1800s manual_hold=120s
[2026-03-10 12:00:32] [INFO] [Front Door] → Slot 1 [HTTP 200]

# PTZ manual control detection (any axis — pan, tilt, or zoom)
[2026-03-10 12:02:00] [WARN] [Front Door] PTZ drift: pan=22200/18500 tilt=9400/9400 zoom=873/873
[2026-03-10 12:02:00] [WARN] [Front Door] External control detected — holding patrol for 120s
[2026-03-10 12:04:00] [INFO] [Front Door] Manual control hold expired — resuming patrol

# Motion during dwell
[2026-03-10 12:05:02] [INFO] [Gate PTZ] Activity during dwell — holding
[2026-03-10 12:05:02] [INFO] [Gate PTZ] Tracking/motion active — holding (motion)

# Goto that the camera did not complete (patrol sends it again)
[2026-03-10 12:06:15] [WARN] [Gate PTZ] Goto target not acquired — live pan=22562 tilt=11078 zoom=0, target pan=20663 tilt=11737 zoom=0
[2026-03-10 12:06:15] [WARN] [Gate PTZ] Re-issued goto for slot 1 after failed execution (attempt 1/2, HTTP 200)

# Fixed-camera cues
[2026-03-10 12:00:02] [INFO] [Pole PTZ] Cues: Gate Cam→4, Path Cam→0, Path Cam→3
[2026-03-10 12:07:10] [INFO] [Pole PTZ] Cue: Gate Cam person (Trail) → slot 4
[2026-03-10 12:07:52] [INFO] [Pole PTZ] Tracking ended at pan 25436 tilt 9565 zoom 1381
[2026-03-10 12:07:52] [INFO] [Pole PTZ] Tracking lost — Cue: Path Cam person (Far side) → slot 0

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
[2026-03-10 12:10:05] [INFO] [Driveway] Tracking/motion active — holding (tracking)
[2026-03-10 12:11:10] [INFO] [Driveway] Activity hold ended after 65s (tracking 65s, smart 0s, motion 0s)
[2026-03-10 12:11:10] [INFO] [Driveway] → Slot 4 [HTTP 200]

# Auto-setup on startup
[2026-03-10 12:00:01] [INFO] [main] Front Door: disabled auto-tracking for dynamic mode (was ["person"])
[2026-03-10 12:00:01] [INFO] [main] Front Door: stopped built-in patrol (was slot 0)

# Schedule pause/resume
[2026-03-10 06:00:01] [INFO] [Front Door] Outside schedule window (22:00-06:00) — pausing patrol
[2026-03-10 06:00:01] [INFO] [Front Door] Sent to home position
[2026-03-10 22:00:01] [INFO] [Front Door] Schedule window active (22:00-06:00) — resuming patrol

# Constrained schedule pause/resume
[2026-03-10 22:45:01] [INFO] [Front Door] Outside schedule window (22:00-06:00, constrained to minutes 15 through 45 after the hour) — pausing patrol
[2026-03-10 23:15:01] [INFO] [Front Door] Schedule window active (22:00-06:00, constrained to minutes 15 through 45 after the hour) — resuming patrol

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

### Logs stop partway through the day

**Symptom:** `journalctl -u ptz-patrol` shows no new lines, but `systemctl status ptz-patrol` shows an active service with a live MainPID, and the cameras still move. A restart of `ptz-patrol` does not bring the logs back, not even the startup banner.

Before 1.6.1, the service limits logs to 10,000 lines in a 1-day window. Four cameras can use that budget by mid-morning. Patrol continues, but journald drops the later lines. journald keeps this limit for each unit, so a service restart does not reset it.

Check for dropped messages:

```bash
journalctl -u systemd-journald | grep 'Suppressed .* ptz-patrol'
```

With a 1-day window, journald reports the suppression only when the next window starts. Upgrade to 1.6.1 or later. The updated unit permits 2000 lines in each 30-second window, which still limits a runaway loop. The installer replaces the unit and reloads systemd on upgrade. Bootstrap restores it after a firmware update removes the unit.

`systemctl restart systemd-journald` clears journald's rate-limit state inside the window, but upgrading is the fix.

To confirm that patrol still runs while the log is silent, watch a camera in the Protect app for one dwell period. Do not use the log for this check.

> **NOTE:** `echo test > /proc/<MainPID>/fd/1` does not test the journald connection. The service's stdout is a socket, and Linux does not open a socket through `/proc`. The command fails with `No such device or address` also when logging works. Earlier versions of this README gave that command as a test.
## Maintenance

Upgrades from versions before 1.2.0 use that version's installer: the daemon logs the version, but `install-info` records the commit after the next `install.sh` run.

```bash
# Service Management
systemctl status ptz-patrol.service    # Current state
systemctl restart ptz-patrol.service   # Apply config changes

# Discovery (see cameras, presets, zoom, effective config)
bash /data/ptz-patrol/discover.sh

# Full Removal
/data/ptz-patrol/uninstall.sh
```

The discovery header reports the installed version and commit. Each camera block shows current auto-tracking object types separately from tracking support and the camera's tracking-with-zoom setting. For example:

```text
  G6 PTZ
  PTZ (firmware):   true
  Auto-tracking now: off
  Tracking support: person
  Tracking with zoom: on
```

## Project Structure

- **ptz-patrol.sh**: Main entrypoint — discovers cameras and launches parallel patrol loops with per-process isolation and graceful shutdown
- **api.sh**: Shared library for auth, HTTP with retry, config caching, motion/tracking detection, PTZ position queries, and log level filtering
- **discover.sh**: PTZ camera discovery and config dump (dual-mode: sourceable + standalone). Fetches presets from the per-camera `/ptz/preset` endpoint (the `ptzPresetPositions` field on camera objects is empty on many firmware versions)
- **patrol.sh**: Core per-camera patrol loop with manual control detection, active dwell monitoring, and error resilience
- **config.json.example**: Example configuration template (copied to `config.json` on install)
- **VERSION** and **CHANGELOG.md**: Release version and release notes, managed by release-please
- **tests/**: Offline bats tests, run by CI with jq 1.6 (see `tests/README.md`)
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

**Compatibility**: Verified on UniFi OS 4.0.0+ with G5 PTZ, G6 PTZ, and AI PTZ Industrial cameras.
**License**: MIT

### Keywords

unifi, unifi-protect, ptz, ptz-patrol, ptz-tour, pan-tilt-zoom, g5-ptz, g6-ptz, ubiquiti, udm, udr, unvr, camera-patrol, preset-tour, motion-aware, auto-tracking, ai-ptz, camera-cues, home-assistant-alternative, bash, systemd, unifi-os
