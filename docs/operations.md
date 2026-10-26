# Patrol implementation and upstream field reports

These implementation notes and historical measurements describe the upstream patrol. They are not performance measurements of cloud mode. Cloud requests add latency and depend on internet connectivity.

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

- **API retry**: GET and POST wrappers retry selected operations; PATCH setup calls do not use those wrappers. Cloud authentication checks access again but cannot renew an expired or revoked API key.
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

