# Changelog

All notable changes are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

* GitHub Actions CI for pull requests and `main` (unit tests, Release build, package artifact) and a tag driven release workflow (`vX.Y.Z`) that checks the tag against `src/version.h` and `CHANGELOG.md` and publishes `foo_component_updater_mac.fb2k-component` with `SHA256SUMS`.
* `Scripts/ci_sdk.sh`: downloads, verifies and builds the foobar2000 SDK libraries.

## [0.1.0] - 2026-10-21

First version. Notify only.

### Added

* Help menu command "Check for Component Updates..." and a results window (component, installed, latest, status, source, release notes).
* Preferences page "Component Updates" under Tools: a short summary, automatic check every 1 to 30 days with the time of the last check (any kind of check counts), prereleases, Check Now, a "?" help popover and collapsed "Custom sources" with strict validation, an Insert Example button and a short help popover that links to `docs/custom-sources.md`.
* The results window remembers its size, position and column widths, and attaches to a running automatic check.
* Results window checkbox "Show built in components" (off by default) for the rows of foobar2000's built in parts.
* Automatic check 20 seconds after start and every 6 hours while foobar2000 runs, when due. One check runs at a time.
* Choosing foobar2000's own "Check For New Versions" (app menu) or "Check for new foobar2000 versions" (Help menu) also runs the component check.
* Source resolution: user mappings, `FB2KUpdateSource` in a component's `Info.plist`, the shared registry of p2ashiura, a built in list of the `foo_jl_*` components, the foobar2000.org catalog.
* GitHub release selection by package file name, one request per repository (at most 3 pages), tag version rule, rate limit handling that holds across checks.
* Port of the update checking core of foo_component_update_checker 2.3.0 (p2ashiura, MIT), see `UPSTREAM` and `docs/sdk-quirks.md`.
* Unit tests for the version comparison, the six upstream parsers, GitHub releases, the catalog page, mapping validation and source resolution, run before every build.
* `Scripts/package.sh`: zips the Release build as `mac/foo_component_updater_mac.component` into `build/foo_component_updater_mac.fb2k-component`, prints its SHA256 and verifies the layout.
* `Scripts/test_batch.sh m1`: headless test batch in the real foobar2000 against GitHub and a local HTTPS stub.
* Debug builds only: the config keys `foo_component_updater_mac.debug.api_base`, `foo_component_updater_mac.debug.autotest` and `foo_component_updater_mac.debug.recheck_seconds`.
