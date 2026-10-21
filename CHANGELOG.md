# Changelog

All notable changes are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
