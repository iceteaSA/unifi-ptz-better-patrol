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
