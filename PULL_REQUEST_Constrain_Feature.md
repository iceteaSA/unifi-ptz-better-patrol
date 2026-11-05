# Pull Request

## Description

Add the ability to optionally constrain the patrol period to a specific "minutes after the hour" window that repeats within the defined schedule, altering the default behavior of operating patrol mode continually throughout the schedule.

## Use Cases

Initially investigated to address a temporary gap in coverage in a new deployment, but was identified as beneficial in a number of other situations, broadly two driving factors:

1. ***Scenario Specific*** - Situation where a PTZ camera covers a high traffic area by default, but also has visibility to other key areas that are not adequately covered by other cameras.  Particularly useful if tracking is enabled or camera is moved locally where its default view would not have picked up activity that could have crossed the home monitoring area to an area of interest.  Can also be beneficial where there is a desire for increased local control of a camera to limit "wrestling" with patrol, communicate a known, shorter patrol period and more successfully capture an ongoing record of patrol areas.  Overall, this mechanism enables a less frequent "spot check" record of a key area on a predictive schedule, while prioritizing monitoring of the home region or local control.

2. ***Reduce Duty Cycle*** - Provide more refined control of the load on the PTZ motors without increasing the dwell time across defined presets to balance camera wear with patrol coverage and patrol schedule.


## Approach and Considerations

Considered several alternative approaches including a `cron`-style schedule implementation but ultimately settled on a simplified "minutes-past-hour-start to minutes-past-hour-end" optional configuration parameter that will not break current configurations, retains default behavior and aligns to the general approach and style of the current implementation.

The feature introduces two optional configuration parameters for the `config.json` file and alters [only] the `patrol.sh` script with additional processing logic occuring after the schedule start/end evaluation but before the schedule day evaluation to determine whether the current evaluated time falls within the defined constraint window.

## Type of Change

- [ ] Bug fix (non-breaking change that fixes an issue)
- [x] New feature (non-breaking change that adds functionality)
- [ ] Breaking change (fix or feature that would cause existing functionality to not work as expected)
- [ ] Documentation update
- [ ] Code refactoring (no functional changes)

## Changes Made

Detailed list of changes:

- Two new schedule configuration parameters for `config.json`: `constrain_start_minute` and `constrain_end_minute` as numeric parameters given that the `_minute` unit is defined
- Added logic to `patrol.sh` to continue existing behavior if either parameter is not defined, is invalid (does not evaluate to between `0` and `59`) or if the two parameters are equal
- Aligned to general approach of `sched_start` and `sched_end` processing to perform evaluation of whether within a defined constrained period and immediately return `1` if outside the period or continue to evaluate the day schedule
- Adjusted logging to reflect message with constrain information if valid/defined/active or continue with existing logging if optional constrain functionality is not being used

## Testing

### Test Environment

- **Device Model**: UNVR
- **PTZ Camera Model**: G6 PTZ
- **UniFi Protect Version**: 7.3.70
- **Test Duration**: 5 hours including config-restart multiple scenarios and steady run over multiple hours

### Test Scenarios

- [x] Patrol cycling (correct preset sequence)
- [x] Motion hold (pause on motion/smart detection)
- [x] Manual control detection (zoom drift)
- [ ] Dynamic auto-tracking (enable/disable cycle)
- [x] Schedule (pause/resume at window boundaries)
- [ ] Error recovery (auth failures, API errors)
- [x] Startup (discovery, auto-setup)
- [x] Shutdown (graceful cleanup)
- [x] Shellcheck passes: `shellcheck -s bash api.sh discover.sh patrol.sh ptz-patrol.sh install.sh uninstall.sh`
- [ ] Other:

### Test Results

```
Base test config.json:
{
  "nvr_address": "[URL]",
  "username": "[USER]",
  "password": "[PASS]",
  "reauth_seconds": 3600,
  "auto_discover": true,
  "rediscovery_interval_seconds": 0,
  "log_level": "info",
  "defaults": {
    "dwell_seconds": 30,
    "motion_hold_seconds": 15,
    "max_tracking_wait": 300,
    "manual_control_hold_seconds": 120,
    "_note_ptz_settle": "ptz_settle_seconds is auto-clamped to at most dwell_seconds/2 at startup",
    "ptz_settle_seconds": 10,
    "home_on_shutdown": true,
    "home_between_cycles": false,
    "schedule": null,
    "dynamic_auto_tracking": false
  },
  "camera_overrides": {
    "[CAM1]": {
      "enabled": true,
      "dwell_seconds": 45,
      "motion_hold_seconds": 20,
      "max_tracking_wait": 360,
      "manual_control_hold_seconds": 240,
      "ptz_settle_seconds": 5,
      "preset_slots": [
        6,
        3,
        4,
        5,
        8,
        9
      ],
      "schedule": {
        "start": "15:40",
        "end": "18:30",
        "days": [
          "mon",
          "tue",
          "wed",
          "thu",
          "fri"
        ],
        "constrain_start_minute": 45,
        "constrain_end_minute": 45,
        "home_on_pause": true
      },
      "dynamic_auto_tracking": false
    }
  }
 }

Test: Constrain minutes defined but equal, ignored and camera follows default behavior and logs do not include constrained window information.
Result:
Nov 05 15:36:24 NLCC-Sentinel systemd[1]: Started ptz-patrol.service - UniFi PTZ Patrol with Motion-Aware Tracking.
Nov 05 15:36:25 NLCC-Sentinel ptz-patrol.sh[544859]: [2026-11-05 15:36:25] [INFO] [api] Authenticated
Nov 05 15:36:25 NLCC-Sentinel ptz-patrol.sh[544859]: [2026-11-05 15:36:25] [INFO] [main] Discovering PTZ cameras...
Nov 05 15:36:25 NLCC-Sentinel ptz-patrol.sh[544859]: [2026-11-05 15:36:25] [INFO] [main] Found 1 PTZ camera(s) — launching patrol loops
Nov 05 15:36:25 NLCC-Sentinel ptz-patrol.sh[544859]: [2026-11-05 15:36:25] [INFO] [main] Corner Entrance PTZ: patrol launched (PID 544960)
Nov 05 15:36:25 NLCC-Sentinel ptz-patrol.sh[544960]: [2026-11-05 15:36:25] [INFO] [api] Authenticated
Nov 05 15:36:25 NLCC-Sentinel ptz-patrol.sh[544960]: [2026-11-05 15:36:25] [INFO] [Corner Entrance PTZ] A sub-hour constrained patrol period has not been defined or is invalid.  Patrol will run for the default full schedule period.
Nov 05 15:36:25 NLCC-Sentinel ptz-patrol.sh[544960]: [2026-11-05 15:36:25] [INFO] [Corner Entrance PTZ] Patrol: presets=[6 3 4 5 8 9] dwell=45s settle=5s poll=5s hold=20s max_wait=360s manual_hold=240s schedule=15:40-16:30 days=mon,tue,wed,thu,fri home_on_pause=true
Nov 05 15:36:25 NLCC-Sentinel ptz-patrol.sh[544960]: [2026-11-05 15:36:25] [INFO] [Corner Entrance PTZ] Outside schedule window (15:40-16:30) — pausing patrol
Nov 05 15:36:26 NLCC-Sentinel ptz-patrol.sh[544960]: [2026-11-05 15:36:26] [INFO] [Corner Entrance PTZ] Sent to home position

Config:
...
"schedule": {
        "start": "15:40",
        "end": "18:30",
        "days": [
          "mon",
          "tue",
          "wed",
          "thu",
          "fri"
        ],
        "constrain_start_minute": 45,
        "constrain_end_minute": 50,
        "home_on_pause": true
      }
...

Test: Constrained window defined and valid, wait for active and react to external control, pausing when control returns beyond constrained period
Result:
Nov 05 15:37:09 NLCC-Sentinel systemd[1]: Started ptz-patrol.service - UniFi PTZ Patrol with Motion-Aware Tracking.
Nov 05 15:37:10 NLCC-Sentinel ptz-patrol.sh[545342]: [2026-11-05 15:37:10] [INFO] [api] Authenticated
Nov 05 15:37:10 NLCC-Sentinel ptz-patrol.sh[545342]: [2026-11-05 15:37:10] [INFO] [main] Discovering PTZ cameras...
Nov 05 15:37:10 NLCC-Sentinel ptz-patrol.sh[545342]: [2026-11-05 15:37:10] [INFO] [main] Found 1 PTZ camera(s) — launching patrol loops
Nov 05 15:37:10 NLCC-Sentinel ptz-patrol.sh[545342]: [2026-11-05 15:37:10] [INFO] [main] Corner Entrance PTZ: patrol launched (PID 545435)
Nov 05 15:37:10 NLCC-Sentinel ptz-patrol.sh[545435]: [2026-11-05 15:37:10] [INFO] [api] Authenticated
Nov 05 15:37:10 NLCC-Sentinel ptz-patrol.sh[545435]: [2026-11-05 15:37:10] [INFO] [Corner Entrance PTZ] Active constrained patrol period window: 45 through 50 minutes past the hour.
Nov 05 15:37:10 NLCC-Sentinel ptz-patrol.sh[545435]: [2026-11-05 15:37:10] [INFO] [Corner Entrance PTZ] Patrol: presets=[6 3 4 5 8 9] dwell=45s settle=5s poll=5s hold=20s max_wait=360s manual_hold=240s schedule=15:40-16:30 constrain_patrol_minutes=45-50 days=mon,tue,wed,thu,fri home_on_pause=true
Nov 05 15:37:10 NLCC-Sentinel ptz-patrol.sh[545435]: [2026-11-05 15:37:10] [INFO] [Corner Entrance PTZ] Outside constrained schedule window (15:40-16:30, limited to minutes 45 through 50 after the hour) — pausing patrol
Nov 05 15:37:10 NLCC-Sentinel ptz-patrol.sh[545435]: [2026-11-05 15:37:10] [INFO] [Corner Entrance PTZ] Sent to home position
Nov 05 15:45:11 NLCC-Sentinel ptz-patrol.sh[545435]: [2026-11-05 15:45:11] [INFO] [Corner Entrance PTZ] Constrained schedule window active (15:40-18:30, between minutes 45 through 50 after the hour) — resuming patrol
Nov 05 15:45:11 NLCC-Sentinel ptz-patrol.sh[545435]: [2026-11-05 15:45:11] [INFO] [Corner Entrance PTZ] Camera settled before patrol start after 0s
Nov 05 15:45:11 NLCC-Sentinel ptz-patrol.sh[545435]: [2026-11-05 15:45:11] [INFO] [Corner Entrance PTZ] → Slot 6 [HTTP 200]
Nov 05 15:45:58 NLCC-Sentinel ptz-patrol.sh[545435]: [2026-11-05 15:45:58] [INFO] [Corner Entrance PTZ] → Slot 3 [HTTP 200]
Nov 05 15:46:45 NLCC-Sentinel ptz-patrol.sh[545435]: [2026-11-05 15:46:45] [INFO] [Corner Entrance PTZ] → Slot 4 [HTTP 200]
Nov 05 15:47:31 NLCC-Sentinel ptz-patrol.sh[545435]: [2026-11-05 15:47:31] [INFO] [Corner Entrance PTZ] → Slot 5 [HTTP 200]
Nov 05 15:48:18 NLCC-Sentinel ptz-patrol.sh[545435]: [2026-11-05 15:48:18] [INFO] [Corner Entrance PTZ] → Slot 8 [HTTP 200]
Nov 05 15:48:28 NLCC-Sentinel ptz-patrol.sh[545435]: [2026-11-05 15:48:28] [WARN] [Corner Entrance PTZ] Goto target not acquired — live position remains off target
Nov 05 15:48:29 NLCC-Sentinel ptz-patrol.sh[545435]: [2026-11-05 15:48:29] [WARN] [Corner Entrance PTZ] Re-issued goto for slot 8 after failed execution (attempt 1/2, HTTP 200)
Nov 05 15:48:54 NLCC-Sentinel ptz-patrol.sh[545435]: [2026-11-05 15:48:54] [INFO] [Corner Entrance PTZ] PTZ drift detected: pan(10900→6100) tilt(11800→10200)
Nov 05 15:48:59 NLCC-Sentinel ptz-patrol.sh[545435]: [2026-11-05 15:48:59] [INFO] [Corner Entrance PTZ] PTZ drift detected: pan(10900→4900) tilt(11800→9400) zoom(0→650)
Nov 05 15:48:59 NLCC-Sentinel ptz-patrol.sh[545435]: [2026-11-05 15:48:59] [INFO] [Corner Entrance PTZ] External control detected — holding patrol for 240s
Nov 05 15:51:00 NLCC-Sentinel ptz-patrol.sh[545435]: [2026-11-05 15:51:00] [INFO] [Corner Entrance PTZ] Outside constrained schedule window (15:40-16:30, limited to minutes 45 through 50 after the hour) — pausing patrol
Nov 05 15:51:00 NLCC-Sentinel ptz-patrol.sh[545435]: [2026-11-05 15:51:00] [INFO] [Corner Entrance PTZ] Sent to home position


Config:
...
      "schedule": {
        "start": "15:40",
        "end": "18:30",
        "days": [
          "mon",
          "tue",
          "wed",
          "thu",
          "fri"
        ],
        "constrain_start_minute": 15,
        "constrain_end_minute": 22,
        "home_on_pause": true
      }
...

Test: Repeat test with camera unencumbered through window.
Result:
Nov 05 16:10:45 NLCC-Sentinel systemd[1]: Started ptz-patrol.service - UniFi PTZ Patrol with Motion-Aware Tracking.
Nov 05 16:10:45 NLCC-Sentinel ptz-patrol.sh[560102]: [2026-11-05 16:10:45] [INFO] [api] Authenticated
Nov 05 16:10:45 NLCC-Sentinel ptz-patrol.sh[560102]: [2026-11-05 16:10:45] [INFO] [main] Discovering PTZ cameras...
Nov 05 16:10:45 NLCC-Sentinel ptz-patrol.sh[560102]: [2026-11-05 16:10:45] [INFO] [main] Found 1 PTZ camera(s) — launching patrol loops
Nov 05 16:10:45 NLCC-Sentinel ptz-patrol.sh[560102]: [2026-11-05 16:10:45] [INFO] [main] Corner Entrance PTZ: patrol launched (PID 560197)
Nov 05 16:10:46 NLCC-Sentinel ptz-patrol.sh[560197]: [2026-11-05 16:10:46] [INFO] [api] Authenticated
Nov 05 16:10:46 NLCC-Sentinel ptz-patrol.sh[560197]: [2026-11-05 16:10:46] [INFO] [Corner Entrance PTZ] Active constrained patrol period window: 15 through 22 minutes past the hour.
Nov 05 16:10:46 NLCC-Sentinel ptz-patrol.sh[560197]: [2026-11-05 16:10:46] [INFO] [Corner Entrance PTZ] Patrol: presets=[6 3 4 5 8 9] dwell=45s settle=5s poll=5s hold=20s max_wait=360s manual_hold=240s schedule=15:40-18:30 constrain_patrol_minutes=15-22 days=mon,tue,wed,thu,fri home_on_pause=true
Nov 05 16:10:46 NLCC-Sentinel ptz-patrol.sh[560197]: [2026-11-05 16:10:46] [INFO] [Corner Entrance PTZ] Outside constrained schedule window (15:40-18:30, limited to minutes 15 through 22 after the hour) — pausing patrol
Nov 05 16:10:46 NLCC-Sentinel ptz-patrol.sh[560197]: [2026-11-05 16:10:46] [INFO] [Corner Entrance PTZ] Sent to home position
Nov 05 16:15:46 NLCC-Sentinel ptz-patrol.sh[560197]: [2026-11-05 16:15:46] [INFO] [Corner Entrance PTZ] Constrained schedule window active (15:40-18:30, between minutes 15 through 22 after the hour) — resuming patrol
Nov 05 16:15:46 NLCC-Sentinel ptz-patrol.sh[560197]: [2026-11-05 16:15:46] [INFO] [Corner Entrance PTZ] Camera settled before patrol start after 0s
Nov 05 16:15:46 NLCC-Sentinel ptz-patrol.sh[560197]: [2026-11-05 16:15:46] [INFO] [Corner Entrance PTZ] → Slot 6 [HTTP 200]
Nov 05 16:16:33 NLCC-Sentinel ptz-patrol.sh[560197]: [2026-11-05 16:16:33] [INFO] [Corner Entrance PTZ] → Slot 3 [HTTP 200]
Nov 05 16:17:20 NLCC-Sentinel ptz-patrol.sh[560197]: [2026-11-05 16:17:20] [INFO] [Corner Entrance PTZ] → Slot 4 [HTTP 200]
Nov 05 16:18:07 NLCC-Sentinel ptz-patrol.sh[560197]: [2026-11-05 16:18:07] [INFO] [Corner Entrance PTZ] → Slot 5 [HTTP 200]
Nov 05 16:18:54 NLCC-Sentinel ptz-patrol.sh[560197]: [2026-11-05 16:18:54] [INFO] [Corner Entrance PTZ] → Slot 8 [HTTP 200]
Nov 05 16:19:41 NLCC-Sentinel ptz-patrol.sh[560197]: [2026-11-05 16:19:41] [INFO] [Corner Entrance PTZ] → Slot 9 [HTTP 200]
Nov 05 16:20:28 NLCC-Sentinel ptz-patrol.sh[560197]: [2026-11-05 16:20:28] [INFO] [Corner Entrance PTZ] → Slot 6 [HTTP 200]
Nov 05 16:21:14 NLCC-Sentinel ptz-patrol.sh[560197]: [2026-11-05 16:21:14] [INFO] [Corner Entrance PTZ] → Slot 3 [HTTP 200]
Nov 05 16:22:01 NLCC-Sentinel ptz-patrol.sh[560197]: [2026-11-05 16:22:01] [INFO] [Corner Entrance PTZ] Outside constrained schedule window (15:40-18:30, limited to minutes 15 through 22 after the hour) — pausing patrol
Nov 05 16:22:01 NLCC-Sentinel ptz-patrol.sh[560197]: [2026-11-05 16:22:01] [INFO] [Corner Entrance PTZ] Sent to home position


```

## Configuration Impact

- [x] No configuration changes required
- [x] New optional configuration parameters added
- [ ] Existing configuration parameters modified

If configuration changes are needed, document them here:

## Documentation

- [x] README.md updated (if needed)
- [ ] AGENTS.md updated (if architecture changed)
- [x] config.json.example updated (if config changed)
- [x] Code comments added/updated

## Checklist

- [x] My code follows the project's style guide (see AGENTS.md)
- [x] All function-local variables use `local`
- [x] All variable expansions are double-quoted
- [x] `local` declarations are separate from subshell assignments
- [x] Shellcheck passes with no warnings
- [x] I have tested my changes on hardware (or explained why not)
- [x] I have updated documentation as needed

---

**By submitting this PR, I confirm that**:
- [x] I have read and agree to follow the [Code of Conduct](../CODE_OF_CONDUCT.md)
- [x] I have read the [Contributing Guidelines](../CONTRIBUTING.md)
- [x] My contribution is licensed under the MIT License
