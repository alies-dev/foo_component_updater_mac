# Changelog

All notable changes are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [0.2.0] - 2026-10-22

### Added

* **Install** in the results window: tick the components with an update, click Install and restart foobar2000 to finish. Only `.fb2k-component` packages with a valid code signature and the same bundle identifier as the installed version are installed; when the installed version has a Developer ID, the new one needs the same Team ID.
* **Restore Previous** (right click on a row) brings back the version the last install replaced.
* **Self update**: this component's own row installs like any other, and Restore Previous works for it too. If a new version of the updater does not load, the README tells how to put the kept version back.
* Five more components are known out of the box: `foo_mac_scrobble`, `foo_vis_projectm_mac`, `foo_cyan_leaf`, `foo_vis_projectMacOS` and `foo_richtext_mac`.
* GitHub releases are matched by more than the exact `<name>.fb2k-component` file name: `foo_example-macos.fb2k-component`, `foo_example-1.2.0-macos-arm64.fb2k-component` and zips such as `foo_example-v1.2.0.zip` count too.

### Removed

* Choosing foobar2000's Check For New Versions no longer also checks components. Use Help > Check for Component Updates... or the automatic check.

### Fixed

* `foo_input_ncm` no longer reports its 2021 Windows release as the latest version.
* A component whose GitHub releases have no matching package (for example `foo_scrobbler_mac`) is now looked up in the foobar2000.org catalog instead of showing an error. Your own custom sources still stay as you wrote them.
* The catalog reader accepts pages that say "Supported system:" for a single platform.
* A package can no longer fill the disk: extraction stops as soon as it has written more than 512 MB, whatever sizes the zip announces, and the update is refused.

### Install

Download `foo_component_updater_mac.fb2k-component` below, open foobar2000 > Settings... > Components, click **+**, choose the file and restart foobar2000. Version 0.1.0 cannot install updates, so install 0.2.0 this way once; later versions can be installed from the results window.

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
