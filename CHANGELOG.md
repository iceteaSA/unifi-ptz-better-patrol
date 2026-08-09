# Changelog

## [1.0.0](https://github.com/iceteaSA/unifi-ptz-better-patrol/compare/v1.0.0...v1.0.0) (2026-08-09)


### Bug Fixes

* bound drift confirmation attempts ([81dd38f](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/81dd38f2b951a0337cee166415dd422e11ed3681))
* install install.sh so the boot hook can re-bootstrap ([df3765f](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/df3765f737510574c5ce1dcccde5d140f90228fc))
* require drift to persist across polls ([e088356](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/e0883565c97bae5f1a5a02c5af103c04bf0f017b))
* resample home baseline until position stabilizes ([f6ce34d](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/f6ce34d4b5987a864457e48b4997f3a709e68356))

## 1.0.0 (2026-08-09)


### Features

* add systemd sandboxing to the service unit ([f472d13](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/f472d139ae5ff49967b54c53e1105aea65f3d661))
* warn when installing from a non-default branch ([9d0ac2d](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/9d0ac2da6dacb37049d9c5be2e94b2d31ea9efb4))


### Bug Fixes

* add timeouts to all curl requests ([6aeded7](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/6aeded7f3a54b51353946e5ca76c331cc0abc366))
* force first release to 1.0.0 via release-as ([04fa21f](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/04fa21fcbc83a8e8f3c2cbf6b3440528ee3c10c8))
* gate manual control on live tracking state ([728d15d](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/728d15d43dc15e270a9d24d8e7ec99908abb4269))
* guard shutdown re-auth before tracking cleanup ([ff88130](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/ff88130457502befb4c90253ad8965e229558c7e))
* infer active tracking from smart detection when flags are absent ([4158ea2](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/4158ea2c7032618de0774d1e5db00786e58966ed))
* keep scheduled home retry state in patrol shell ([f94b1c0](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/f94b1c0e2373706c9bb3e9793187a412df4bc6c2))
* make retry failures visible to patrol loop ([90f733b](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/90f733b14e9c3615e1cf534ddf36764772645d88))
* preserve camera state fields when id is missing ([4e9d29d](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/4e9d29ddfb953bcf9e2733b0e96987d3b80a692c))
* report prolonged unreadable camera holds ([96bbe43](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/96bbe43b2d5a8b7817f0e5311ba45a08958d4e7f))

### Pre-existing functionality at 1.0.0

The daemon had been running in production for five months before its first
tagged release; the generated notes above cover only the changes made since
conventional commits were adopted. Baseline features:

- Motion-aware patrol with active dwell monitoring
- Manual-control detection and auto-tracking compatibility
- Dynamic auto-tracking, automatic setup, and camera discovery
- Per-camera overrides, schedules, parallel patrol loops, and configurable logs
- Retry and re-auth handling, graceful shutdown, and firmware-update survival
