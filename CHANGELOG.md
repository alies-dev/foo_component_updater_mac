# Changelog

All notable changes are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [0.3.1] - 2026-10-26

### Added

* Click a column title to sort by it. Released sorts newest first.

### Install

Version 0.2.0 or later: tick this component in the results window, click Install and restart foobar2000. Version 0.1.0: open foobar2000 > Settings... > Components, click **+**, choose `foo_component_updater_mac.fb2k-component` and restart foobar2000.

## [0.3.0] - 2026-10-26

### Added

* Update checks for foo_dms_browser (UPnP) and foo_lastfm.
* A Released column with the date of the latest release.
* Hover over Release notes to read them, and over a component's name for its description.
* Prereleases are marked "(beta)" in the Latest column.

### Changed

* The Source column is gone; hover over the latest version to see where it was found.

### Install

Version 0.2.0 or later: tick this component in the results window, click Install and restart foobar2000. Version 0.1.0: open foobar2000 > Settings... > Components, click **+**, choose `foo_component_updater_mac.fb2k-component` and restart foobar2000.

## [0.2.2] - 2026-10-23

### Fixed

* The Last check line in Preferences now updates as soon as a check finishes.

### Install

Version 0.2.0 or later: tick this component in the results window, click Install and restart foobar2000. Version 0.1.0: open foobar2000 > Settings... > Components, click **+**, choose `foo_component_updater_mac.fb2k-component` and restart foobar2000.

## [0.2.1] - 2026-10-22

### Changed

* The download is about 60% smaller.

### Install

Version 0.2.0: tick this component in the results window, click Install and restart foobar2000. Version 0.1.0: open foobar2000 > Settings... > Components, click **+**, choose `foo_component_updater_mac.fb2k-component` and restart foobar2000.

## [0.2.0] - 2026-10-22

### Highlights

* **Install updates** from the results window: tick the components, click Install, restart foobar2000. Only signed packages that match the installed component are installed.
* **Restore Previous** (right click on a row) brings back the version the last install replaced.
* **Updates itself** the same way.
* Finds more components: more GitHub package names are recognised, the foobar2000.org catalog is used as a fallback, and five more components are known out of the box.

### Changed

* foobar2000's own Check For New Versions no longer also checks components.

### Install

Download `foo_component_updater_mac.fb2k-component` below, open foobar2000 > Settings... > Components, click **+**, choose the file and restart foobar2000. 0.1.0 cannot install updates, so do this once.

Tested with foobar2000 2.26 on macOS 26; requires macOS 12 or later.

## [0.1.0] - 2026-10-21

foobar2000 for Mac checks only its own core for updates. This component checks the components you added.

### Highlights

* **Help > Check for Component Updates...** lists your components with the installed and the latest version.
* Finds updates on GitHub (including repositories that ship several components), in the official foobar2000.org catalog and in the shared component registry. Authors can declare their source with an `FB2KUpdateSource` key in `Info.plist`.
* Checks on its own every 7 days by default, and whenever you choose foobar2000's **Check For New Versions**.
* Reports only: this version does not download or install anything.

### Install

Download `foo_component_updater_mac.fb2k-component` below, open foobar2000 > Settings... > Components, click **+**, choose the file and restart foobar2000.

Tested with foobar2000 2.26 on macOS 26; requires macOS 12 or later.
