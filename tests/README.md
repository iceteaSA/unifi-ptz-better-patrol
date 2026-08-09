# Bats tests

This suite runs `is_tracking` with injected camera-state JSON. It performs no
network requests, needs no NVR or root access, and sets `_LOG_LEVEL=3` so every
warning is visible. The target device uses Bash 5.1.4 and jq 1.6; tests avoid
jq features newer than 1.6. The development host may have a newer jq.

## Setup

Install the pinned Bats runner locally:

```bash
npm install --prefix tests/.bats bats@1.13.0 --no-audit --no-fund
```

The local runner is ignored by Git. CI can run the same setup command.

## Run

```bash
tests/.bats/node_modules/.bin/bats tests/
```

The missing-field test is a characterization test for a known source defect:
`.id // empty` once collapsed the positional jq `@tsv` output when `id` was
absent. It now asserts the corrected invalid-response fail-safe.

## Hardware fixture

`fixtures/camera-0.json` is derived from a live UNVR camera response. The
camera identifier was replaced with `fixture-camera-0`, and the camera name was
removed. No hostnames, addresses, credentials, tokens, MACs, serials, or real
camera names remain. The presets response was not copied because `is_tracking`
only consumes camera-state JSON.

`patrol_drift.bats` sources the patrol library and uses queue-backed PTZ/API
stubs to exercise all three drift call sites. It covers convergence, the
confirmation streak and attempt cap, fail-safe reads, and two-read home
baseline stabilization without sleeping or contacting hardware.

`failed_goto.bats` covers previous-preset classification, the all-axis guard,
the failed-goto side channel, bounded re-issues, and fail-safe position reads.

The patrol probes pass discovery JSON as the real `launch_patrol_for_camera`
caller does; no test relies on the unreachable empty-discovery call shape.
`startup_settle.bats` covers stable, capped, unreadable, and once-per-loop
startup settling.

### Provenance — read this before trusting the fixture

A fixture is evidence about one system at one moment, not a permanent fact.
Captured **2026-08-09** from:

| | |
|---|---|
| Device | UNVR, `UNVR4.al324.v5.1.25.84c48e7.260710.1602` |
| unifi-protect | 7.1.87 |
| unifi-core | 5.1.126 |
| Camera | UVC G6 PTZ |
| Captured via | `curl` against `/proxy/protect/api/cameras/{id}`, parsed with jq 1.6 |

**The load-bearing observation:** across 19 samples of 4 PTZ cameras (76 records),
`isAutoTracking`, `isPtzAutoTracking` and `isTracking` were *absent* — `has()`
returned false, not merely null — in every record. That included a 104-second
window where one camera reported `isSmartDetected: true` continuously while
configured with `autoTrackingObjectTypes: ["person"]`, which is precisely when
the camera should have been auto-tracking.

That is why `is_tracking` infers active tracking from `autoTrackingObjectTypes`
plus `isSmartDetected` rather than trusting the three status flags: on this
firmware the flags never appear, so a gate reading only them can never fire.

If a future Protect release starts populating those fields, this reasoning needs
re-checking. Re-sample before assuming either way.
