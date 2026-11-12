# Changelog

## [1.3.0](https://github.com/iceteaSA/unifi-ptz-better-patrol/compare/v1.2.0...v1.3.0) (2026-11-12)


### Features

* configurable auto-tracking object types and zoom ([8ca0f06](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/8ca0f0630addb15ecda4b0d17223f41b27f2b2e9))
* post patrol status to a webhook ([4642811](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/4642811dc116ded7e0bbee1565680bebcbc6ac1a))
* tracking object types, tracking zoom, Home Assistant status webhook ([59ce372](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/59ce372fa1a0453e2e657ade95965abfb040a800))


### Bug Fixes

* keep the config private when an older installer upgrades ([715ba5a](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/715ba5ac5a69fd8774751184765f454e8c11480a))
* protect the webhook secret and config file ([9474961](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/9474961487da1a5e82896a1230c38ed43baee711))
* report the version when an older installer upgrades ([c901b9a](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/c901b9a1d6559e10a4bc7355b6085808245dfaf7))
* tighten tracking and status edge cases ([e71165d](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/e71165ddc5954f8d54350e3d231b9e267c193764))


### Documentation

* align batch 2 code and docs with project conventions ([41bbba3](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/41bbba343a649f27a07e10217ec13b44d976d8a2))


### Code Refactoring

* align field-report code with project conventions ([da57165](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/da57165974a3ee5379f052e2ddf035d115b2d2ce))

## [1.2.0](https://github.com/iceteaSA/unifi-ptz-better-patrol/compare/v1.1.0...v1.2.0) (2026-11-12)


### Features

* add per-preset dwell times ([913a679](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/913a67903d1c8da5e58129594aab169cd92bae33))
* add pingpong patrol path ([8b487b8](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/8b487b8c5414822a2334279f8373846841d3b4e5))
* per-preset dwell, pingpong path, installed version, HomeView fix ([d17b885](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/d17b8859eb8ebf848e9807d41579f27d3d1f8793))
* record and log the installed version ([dbb9dc4](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/dbb9dc43bc38f2d683e47c78ae77a9713056b281))


### Bug Fixes

* clarify discovery output and warn on duplicate camera names ([218da65](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/218da65f3aa8d274a731be32919c6f33859429d3))
* do not treat a HomeView return as manual control ([e4bca0c](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/e4bca0c2bf13520e19fe137e456cf17ca453d1a9))
* harden install metadata and discovery parsing ([b5a63ef](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/b5a63ef3b797e0ea85d018a9f223bfdb5c67ee16))
* keep per-slot timing safe and document the new invariants ([11b76e9](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/11b76e9e1aa1ee440768d8839043dddba008d4dd))
* refresh renamed cameras and tag duplicate names ([8e7eac7](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/8e7eac7c2da6fdb36815e8d6c10ba599b38e3cd9))
* tag only duplicate camera names and keep discovery lines per camera ([3c0bc19](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/3c0bc19cb47caadf658076b00894225587030e20))
* write install-info before the service starts ([62ad720](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/62ad72032163c1ec73ffdea8203734c10209faa3))


### Documentation

* align AGENTS.md and the log sample with the new behaviour ([8f715a5](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/8f715a52c3be584c3fc1c38ebb8473245971001a))
* simplify the new configuration text ([77770f6](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/77770f649310a4036aaffab838112c2d7f02e518))


### Continuous Integration

* drop the release PR CI dispatch and document run approval ([#17](https://github.com/iceteaSA/unifi-ptz-better-patrol/issues/17)) ([c61700a](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/c61700a8f1f16ac621e5896c11eb3c9021643c74))
* run CI on release PRs and document the main rulesets ([#15](https://github.com/iceteaSA/unifi-ptz-better-patrol/issues/15)) ([6233a5e](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/6233a5e8f427d5efbcbfed4966816d7ff02591e6))

## [1.1.0](https://github.com/iceteaSA/unifi-ptz-better-patrol/compare/v1.0.4...v1.1.0) (2026-11-06)


### Features

* add option to constrain patrol to a reduced window ([#12](https://github.com/iceteaSA/unifi-ptz-better-patrol/issues/12)) ([0474769](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/04747690f6664d43278555f9c203564e24175c72))


### Bug Fixes

* honour enabled:false in camera config ([a13ee64](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/a13ee6466307e28cef998029f56ecfb40caebdfe))


### Documentation

* correct the deploy list, boolean defaults and test guidance ([7ad95f0](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/7ad95f0d396ab0ced9a233d1850162df95795075))
* describe the test suite, CI gates and release assets ([93c5d45](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/93c5d4540913a0a8da36cdf1ace5dab66f27791a))


### Tests

* run the enabled tests through the patrol helper ([91c14c0](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/91c14c0d82d28881ef1c99ad3588a7b230d6f5bb))


### Continuous Integration

* gate releases on checks and attach release assets ([95c22dd](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/95c22dda48f23eda4ffe994e832aacf05cf7a745))
* list every documented commit type in release notes ([b73b80c](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/b73b80c7bd8a1031fdcb4a30967699214059bb36))
* run actionlint on the workflow files ([a6b105e](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/a6b105ec672195806b4824000d28ef15eb48711c))

## [1.0.4](https://github.com/iceteaSA/unifi-ptz-better-patrol/compare/v1.0.3...v1.0.4) (2026-08-10)


### Bug Fixes

* classify off-target position as unacquired goto until the target is reached ([c2ef22d](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/c2ef22d31ad8919dacca1803269f7dfb394bb81c))

## [1.0.3](https://github.com/iceteaSA/unifi-ptz-better-patrol/compare/v1.0.2...v1.0.3) (2026-08-09)


### Bug Fixes

* wait for the camera to settle before starting a patrol loop ([e43bd8d](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/e43bd8ddc772d69a68cdacc08699c5e809deab16))

## [1.0.2](https://github.com/iceteaSA/unifi-ptz-better-patrol/compare/v1.0.1...v1.0.2) (2026-08-09)


### Bug Fixes

* detect a goto that was accepted but never executed ([3b8005e](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/3b8005e7cc459fa1ae342dab88207bc44287aef4))

## [1.0.1](https://github.com/iceteaSA/unifi-ptz-better-patrol/compare/v1.0.0...v1.0.1) (2026-08-09)


### Bug Fixes

* bound drift confirmation attempts ([81dd38f](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/81dd38f2b951a0337cee166415dd422e11ed3681))
* drop release-as pin so releases can advance past 1.0.0 ([295312e](https://github.com/iceteaSA/unifi-ptz-better-patrol/commit/295312e860dd03f712e3a69dcf541fecf910acfa))
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
