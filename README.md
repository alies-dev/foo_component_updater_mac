# foo_component_updater_mac

foobar2000 for Mac checks only itself for updates; this component checks the components you added.

<p align="center">
  <img src="docs/images/results-window.png" alt="The results window listing installed components with installed version, latest version and status" width="720">
  <br>
  <em>Help > Check for Component Updates...: every installed component with its installed and latest version.</em>
</p>

<p align="center">
  <img src="docs/images/preferences.png" alt="The Component Updates preferences page under Tools" width="480">
  <br>
  <em>Preferences > Tools > Component Updates: schedule, prereleases and custom sources.</em>
</p>

## Install

1. Download `foo_component_updater_mac.fb2k-component` from the [Releases](https://github.com/alies-dev/foo_component_updater_mac/releases) page.
2. In foobar2000 open Settings... > Components, click `+` and choose the file.
3. Restart foobar2000.

Requires macOS 12 or newer, Apple Silicon or Intel.

## Features

* A results window with the installed and the latest version of each component, its status and a link to the release notes.
* Installs the updates you tick: select the rows, click Install, then restart foobar2000. The version it replaces is kept, and right click > Restore Previous brings it back. The updater's own row works the same way.
* Finds updates on GitHub (including repositories with several components), in the foobar2000.org catalog and in the shared component registry. Authors can declare their source with an `FB2KUpdateSource` key.
* Checks automatically every few days.
* Custom sources for components it does not know, see [docs/custom-sources.md](docs/custom-sources.md).
* foobar2000's built in components are hidden unless you ask for them.

## Privacy and safety

* Nothing is downloaded or installed until you tick an update and click Install. Only `.fb2k-component` packages are installed (GitHub `.zip` files are only reported), and only from the source the update was found at.
* Before anything is replaced the package must have a valid code signature, the same bundle identifier as the installed component and, when the installed one has a Team ID, the same Team ID. The new version waits in foobar2000's `pending` folder and is applied at the next start.
* HTTPS only. It contacts GitHub (releases and the shared registry), foobar2000.org and the hosts of custom sources you add, and nothing else.
* No personal data, no telemetry.

## If an update breaks the updater itself

Restore Previous is in this component's own window, so it cannot help when the new version does not load. The version it replaced is kept in `~/Library/foobar2000-v2/foo_component_updater_mac/backup/foo_component_updater_mac/`. Either install the older `.fb2k-component` from the Releases page through Settings... > Components > `+`, or put the kept copy back and start foobar2000:

```
cd ~/Library/foobar2000-v2
mkdir -p user-components/pending/foo_component_updater_mac
cp -R foo_component_updater_mac/backup/foo_component_updater_mac/foo_component_updater_mac.component user-components/pending/foo_component_updater_mac/
```

## For component authors

See [docs/component-authors.md](docs/component-authors.md) to make your component updatable.

## Development

```
export FB2K_SDK_PATH=/path/to/SDK-2026-10-01   # built SDK libraries, not part of this repository
./Scripts/build.sh --install                   # unit tests, build, copy into user-components
```

GitHub Actions builds and tests every pull request and every push to `main`. A release is made by pushing a tag `vX.Y.Z` that matches `FCU_VERSION` in `src/version.h`; the matching `CHANGELOG.md` section becomes the release notes, so keep it to a few user visible bullets. More notes are in [docs/sdk-quirks.md](docs/sdk-quirks.md).

## Components with native update support

These components declare their own update source (`FB2KUpdateSource`), so the updater finds them without any catalog or registry:

| Component | Source | Since |
| --- | --- | --- |
| [foo_ui_panels](https://github.com/santiagorod92/foo_ui_panels) | GitHub releases | 1.15.0 |
| [foo_navidrome](https://github.com/santiagorod92/foo_navidrome) | GitHub releases | 1.32.0 |

Older versions of these, and other components, are found through the foobar2000.org catalog, the shared registry or your custom sources when they are listed there.

## Credits

The update checking logic comes from [foo_component_update_checker](https://github.com/p2ashiura/foo_component_update_checker) by p2ashiura (MIT) and its shared registry [foo_component_update_checker-registry](https://github.com/p2ashiura/foo_component_update_checker-registry). The build layout follows [JendaT/fb2k-components-mac-suite](https://github.com/JendaT/fb2k-components-mac-suite). JSON parsing by [nlohmann/json](https://github.com/nlohmann/json).

## License

MIT, see [LICENSE](LICENSE). Copyright 2026 alies-dev, ported files copyright 2026 p2ashiura.
