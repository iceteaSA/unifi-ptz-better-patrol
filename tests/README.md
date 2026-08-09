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
`.id // empty` collapses the positional jq `@tsv` output when `id` is absent.
It must be replaced with an invalid-response assertion after that source bug is
fixed.
