# AGENTS.md

Bash-only daemon that patrols UniFi Protect PTZ cameras. It runs **on the NVR itself**
(UDM / UDR / UNVR / Cloud Key) from `/data/ptz-patrol` under systemd as root.

`CONTRIBUTING.md` and `.github/PULL_REQUEST_TEMPLATE.md` both point contributors here for
the style guide and architecture — keep this file in sync when either changes.

## Verification

There is **no test suite**. The only automated gate is shellcheck, and it currently passes clean:

```bash
shellcheck -s bash api.sh discover.sh patrol.sh ptz-patrol.sh install.sh uninstall.sh
```

Keep it at zero warnings — the PR template has a checkbox for it.

You cannot run the daemon on a dev machine: it needs a live Protect NVR at
`nvr_address` with a local admin user. Verify logic by reading, not by executing.
Runtime checks happen on hardware:

```bash
bash /data/ptz-patrol/discover.sh          # dump cameras, presets, effective config
journalctl -u ptz-patrol.service -f        # all logging goes to the journal, no log files
systemctl restart ptz-patrol.service       # required after ANY config.json edit
```

## Layout and the sourcing chain

Four scripts, sourced (not imported). Beware: **`patrol.sh` and `ptz-patrol.sh` are
different files** and it is easy to edit the wrong one.

| File | Role |
|---|---|
| `ptz-patrol.sh` | **Sole entrypoint.** systemd `ExecStart`. Discovery, per-camera subshells, shutdown. |
| `patrol.sh` | Sourced library: `patrol_camera` (the per-camera loop), external-control + schedule logic. |
| `api.sh` | Sourced base library: auth, HTTP+retry, config, logging, `is_tracking`, PTZ queries. |
| `discover.sh` | Dual-mode: sourced for `discover_ptz_cameras`/`get_camera_config`, or run directly as a CLI dump. |

```
ptz-patrol.sh -> api.sh, patrol.sh
patrol.sh     -> api.sh, discover.sh
discover.sh   -> api.sh
```

- Every sourced file defends `SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"`.
  `BASH_SOURCE[0]`, never `$0` — sourcing must work from any cwd. `CONFIG_FILE` defaults
  from `SCRIPT_DIR` in `api.sh` and is env-overridable.
- `discover.sh` guards its CLI half with `[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0`.
  `return`, not `exit` — changing that breaks every script that sources it.
- **`set -euo pipefail` belongs only in the executables** (`ptz-patrol.sh`, `discover.sh`'s
  direct-run branch, `install.sh`, `uninstall.sh`). Never add it to `api.sh` or `patrol.sh`;
  `set -e` inside a sourced library kills the caller on any non-zero probe.
- `install.sh` deploys only `api.sh discover.sh patrol.sh ptz-patrol.sh` + `uninstall.sh` +
  the unit file. Adding a new script means editing that loop.

## Platform constraints

- Target is UniFi OS (Debian-based, systemd, `apt-get`) — **bashisms are fine**
  (`mapfile`, `declare -A`, `[[ ]]`, `(( ))`). Not busybox.
- Hard deps: `jq` and `curl` (installed by `install.sh`). All JSON goes through `jq` —
  never hand-roll parsing. The one exception is the CSRF token, which is scraped from
  curl's header dump because it is a response header, not a body field.
- The hardware is resource-constrained, so **process spawns are deliberately minimized**:
  `api_get_camera_state` / `is_tracking` extract every field they need in a *single* `jq`
  call, and `date` is called once per cycle. Don't "clean up" these into a chain of
  small `jq`/`date` invocations.
- `date -d "yesterday" || date -v-1d` (GNU/BSD fallback) and `LC_ALL=C date +%a` (locale-proof
  day names) exist on purpose in the schedule code.
- `install.sh` writes `/data/on_boot.d/10-ptz-patrol.sh` so a firmware update (which wipes
  `/etc` and apt packages) re-bootstraps via `install.sh --bootstrap`.

## UniFi Protect API notes

- Base: `$_NVR_ADDRESS/proxy/protect/api`. **Login is the exception** — it POSTs to
  `$_NVR_ADDRESS/api/auth/login` (no `/proxy/protect` prefix) with `{username, password,
  rememberMe:true, token:""}`; the empty `token` field is required.
- Every request needs **all three** of: `TOKEN:` header (`.deviceToken` from the login body),
  `X-CSRF-Token:` header (from the login *response header*), and the cookie jar. `curl -k`
  everywhere — the NVR cert is self-signed; do not "fix" this.
- Re-auth is time-based (`reauth_seconds`, default 3600) via `api_ensure_auth`; 401/403 also
  triggers an immediate re-auth inside the retry wrappers.
- **`ptzPresetPositions` on the camera object is empty on many firmware versions.** Presets
  must come from `GET /cameras/{id}/ptz/preset`.
- `POST /cameras/{id}/ptz/goto/{slot}` returns **200 *or* 204** — treat both as success; 404
  means the slot doesn't exist. **`goto/-1` is the home sentinel**, not a real preset.
- Only `api_patch` sends a request body (`Content-Type: application/json`). `api_post` is a
  bare bodyless POST. `PATCH /cameras/{id}` is used to set
  `smartDetectSettings.autoTrackingObjectTypes` (`["person"]` on, `[]` off) and to null out
  `ptz.returnHomeAfterInactivityMs` (the camera's built-in return-home fights the patrol).
- Auto-tracking flag naming is firmware-dependent — `is_tracking` tolerates
  `.isAutoTracking // .isPtzAutoTracking // .isTracking`. Keep all three.
- `/ptz/position` returns `.steps.{pan,tilt,zoom}` in motor steps, the *same* coordinate
  system as preset `.ptz.{pan,tilt,zoom}`. No ISP/zoom scaling conversion is needed.

## Behavioral invariants

Break these and the camera ends up in a wrong state that nothing corrects.

- **Fail-safe direction is "hold".** Any fetch/parse error, or a camera not `CONNECTED`,
  makes `is_tracking` return `active` so the patrol holds instead of advancing. A failed
  position read reports "not externally controlled". Preserve that asymmetry.
- **The settle-window motion filter is load-bearing.** The camera's own motor movement trips
  its motion sensor, so `is_tracking` ignores `isMotionDetected`/`lastMotion` inside
  `[last_goto_ts, last_goto_ts + settle_seconds]`. Without it, `motion_hold > dwell` becomes
  a permanent hold loop (every goto refreshes `lastMotion`).
- **External-control detection is skipped while auto-tracking is on** — a tracking camera is
  *supposed* to drift off-preset. Drift thresholds are motor steps: pan 200, tilt 200, zoom 30.
  When a manual-control hold expires, expected positions reset to `-1` so stale pre-hold
  values don't immediately re-trigger.
- **`_patrol_home_dwell` mutates caller-scope variables via bash dynamic scoping**
  (`last_goto_ts`, `expected_pan/tilt/zoom`, `tracking_enabled`, `external_control_until`).
  It looks pure from the signature; it is not. Adding `local` for any of those inside it
  silently breaks the loop.
- **Trap ordering in `ptz-patrol.sh`:** `api_init` installs its own `EXIT` trap, so
  `trap shutdown SIGTERM SIGINT EXIT` is set *after* it and overrides it — which is why
  `shutdown()` must call `api_cleanup` itself. `shutdown()` is re-entrancy-guarded because
  EXIT fires again after `exit 0`.
- **Dynamic auto-tracking must be disabled on shutdown** (PATCH `[]` for every id in
  `_DYN_TRACKING_IDS`), otherwise cameras are left tracking with no supervisor.
- Concurrency model: one background subshell per camera, each with its **own** `api_init`,
  cookie jar, temp files and auth token. `patrol_camera` is wrapped in a restart loop
  (exit 2 = permanent, e.g. <2 presets, retry in 300s; anything else retries in 10s).
  A rediscovery loop reaps dead PIDs and launches newly-appeared cameras.

## Config

`config.json` is **gitignored and holds credentials** — never commit it, never echo it into
logs. `config.json.example` is the schema and gets copied to `config.json` on install.

- Merge happens in exactly one place: `get_camera_config` does
  `jq --argjson o "$overrides" '. * $o'` (deep merge, `camera_overrides[id]` wins over `defaults`).
- Field defaults are applied at read time with jq `//` fallbacks in `patrol_camera`.
- `ptz_settle_seconds` is **clamped to `dwell_seconds/2`** (min 1s) at startup so real
  detection windows exist during dwell; poll interval is `min(5, dwell/3)` with a 2s floor.
  Both are documented behavior — `config.json.example` carries a `_note_ptz_settle` key.
- Adding a config field means touching: `config.json.example`, the reader in `patrol.sh`
  (or `api.sh` for top-level fields), README's Configuration section.

## Style

- Prefix functions by module: `api_*`, `patrol_*`, `is_*`, `_` for private helpers.
- All function-local variables use `local`. Split declaration from command substitution
  (`local val; val=$(cmd)`) so exit codes aren't swallowed.
- Always double-quote expansions.
- Read config via `cfg` / `jq -r '... // default'`.
- Log with `log "<tag>" "<level>" "<message>"` (levels `error|warn|info|debug`, filtered by
  `_LOG_LEVEL`). Tag is the camera name, or `api`/`main`. Never `echo` directly.
- Return conventions differ and callers depend on it: `api_get_with_retry` **echoes the body**
  and returns 1 on failure; `api_post_with_retry` **echoes the HTTP code**;
  `api_get`/`api_post`/`api_patch` set the `_LAST_HTTP_CODE` / `_LAST_BODY` globals.

## Contribution workflow

- Branches: `feature/`, `fix/`, `docs/`, `refactor/`.
- Commits: imperative present tense, ≤72-char subject, conventional-style prefixes
  (`feat:`, `fix:`, `docs:`) as used in history.
- PRs use `.github/PULL_REQUEST_TEMPLATE.md` and expect hardware test results (device model,
  camera model, Protect version) — say so explicitly when a change was not hardware-tested.
- Update `README.md` when behavior changes; it documents the patrol loop, detection
  hierarchy and log samples in detail and drifts easily.
