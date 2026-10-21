# foo_component_updater_mac

A foobar2000 for macOS component that finds newer versions of the components you added to foobar2000, such as visualizations, playlists or decoders from GitHub or foobar2000.org.

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

Why: foobar2000's Check For New Versions covers foobar2000 only, not components you added. Built in components update with foobar2000 and are not checked here.

Needed if you added components and want to know when they have newer versions. Not needed if you added none, or you prefer to check yourself: turn off automatic checks, or remove this component in Settings > Components.

Version 0.1.0 only reports. It lists the installed components, finds where each one is published, compares versions and shows the result. Installing updates arrives in a later release.

## Install

1. Download `foo_component_updater_mac.fb2k-component` from the [Releases](https://github.com/alies-dev/foo_component_updater_mac/releases) page.
2. In foobar2000 open Settings... > Components, click `+` and choose the downloaded file.
3. Restart foobar2000.

Requires macOS 12 or newer, Apple Silicon or Intel. The component is ad hoc signed.

## What it does

* Help menu, "Check for Component Updates...": opens a window with one row per installed component: installed version, latest version, status (Update available, Up to date, Unable to compare, No source, Error), where the information came from and a link to the release notes. foobar2000's built in parts are hidden unless you tick "Show built in components".
* Preferences, Tools, "Component Updates": check automatically every 1 to 30 days (with the time of the last check), include prereleases, a Check Now button, a "?" help popover (purpose, why, schedule, needed or not, network), and under "Custom sources" a box for your own mappings (JSON) with Save Sources, Insert Example and a short help popover that links to [docs/custom-sources.md](docs/custom-sources.md).
* The results window remembers its size, position and column widths. Opened while the automatic check runs, it shows that check's results when it finishes.
* An automatic check runs 20 seconds after start and is re-evaluated every 6 hours while foobar2000 runs. Every completed check (Check Now, the Help menu, foobar2000's own "Check For New Versions" or an automatic one) records its time. An automatic check starts when the last check is at least your chosen number of days old, never while another check runs or the results window is open, and opens the window only when an update exists.
* Choosing foobar2000's own "Check For New Versions" (or "Check for new foobar2000 versions" in the Help menu) also runs this check and shows the window.
* Where a component is published is looked up in this order, the first match wins:
  1. Your own mappings (Preferences, Custom sources, see [docs/custom-sources.md](docs/custom-sources.md)).
  2. The `FB2KUpdateSource` key in the component's `Info.plist` (see [docs/component-authors.md](docs/component-authors.md)).
  3. The shared registry of p2ashiura (`known_components.json`, refreshed at most once a day).
  4. A short built in list of the `foo_jl_*` components by JendaT.
  5. The official foobar2000.org component catalog, for components that list macOS support.
* GitHub repositories that hold several components (such as JendaT's suite) cost one API request per check, not one per component. The component package is matched by its file name, `<name>.fb2k-component`.

Custom sources (Preferences, Custom sources) are a JSON array, one object per component. Every field, an example for each source type and the error messages are in [docs/custom-sources.md](docs/custom-sources.md).

```
[
  {"dll": "foo_example", "source": "github", "owner": "someone", "repo": "foo_example"},
  {"dll": "foo_other", "source": "marc2k3", "url": "https://marc2k3.github.io/component/other/"}
]
```

`source` is one of `github`, `gitlab`, `codeberg` (these take `owner` and `repo`) or `marc2k3`, `sourceforge`, `hyv` (these take an https `url`). Invalid text is rejected with the reason in red and the saved value stays.

## What it never does

* It never downloads, installs, replaces or changes anything in this version, and it never writes into `user-components/`.
* It never touches a component that has no source, and never runs or loads downloaded code.
* No personal data is sent: checks contact GitHub and foobar2000.org only.
* HTTPS only, certificates always validated, on every redirect hop.
* No telemetry. The only requests are the registry file, the release data of the sources above and the catalog pages, each with the header `User-Agent: foo_component_updater_mac/<version>`.
* When GitHub answers with a rate limit, it stops calling GitHub until the time GitHub gives, and tells you that time.

## Credits

The update checking logic comes from [foo_component_update_checker](https://github.com/p2ashiura/foo_component_update_checker) by p2ashiura (MIT), pinned in `UPSTREAM`, and its shared registry [foo_component_update_checker-registry](https://github.com/p2ashiura/foo_component_update_checker-registry). The ported files live in `src/upstream/` and every change to them is listed in [docs/sdk-quirks.md](docs/sdk-quirks.md) under "Upstream diff". The build layout follows [JendaT/fb2k-components-mac-suite](https://github.com/JendaT/fb2k-components-mac-suite). JSON parsing by [nlohmann/json](https://github.com/nlohmann/json).

## Documents

* [docs/sdk-quirks.md](docs/sdk-quirks.md): foobar2000 on Mac, as found.
* [docs/custom-sources.md](docs/custom-sources.md): the custom sources format, examples and error messages.
* [docs/component-authors.md](docs/component-authors.md): how to make your component updatable.

## Development

Build from source (macOS 12 or newer, Apple Silicon and Intel, ad hoc signed):

```
export FB2K_SDK_PATH=/path/to/SDK-2026-10-01   # built SDK libraries, not part of this repository
./Scripts/build.sh --install                   # unit tests, build, copy into user-components
```

GitHub Actions builds every pull request and every push to `main` (unit tests, Release build, `foo_component_updater_mac.fb2k-component` as a workflow artifact). `Scripts/ci_sdk.sh` downloads the foobar2000 SDK, verifies its SHA256 and builds its libraries; you can run it locally too.

A release is made by pushing a tag `vX.Y.Z`. The workflow fails unless `X.Y.Z` equals `FCU_VERSION` in `src/version.h` and `CHANGELOG.md` has a `## [X.Y.Z]` section, whose text becomes the release notes. Keep that section short and user visible: a few bullets, no tests or internal items. The release holds `foo_component_updater_mac.fb2k-component` and `SHA256SUMS`.

## License

MIT, see [LICENSE](LICENSE). Copyright 2026 alies-dev, ported files copyright 2026 p2ashiura.
