# foobar2000 and SDK behaviour found on Mac

Facts measured while building this component, with foobar2000 2.26 and `SDK-2026-10-01` on macOS 26. Each fact was observed in the real application: with lsof and inode numbers to see which binary is mapped, debugger breakpoints on file system calls at startup, a throwaway probe component, and the batch in `Scripts/test_batch.sh`.

## Component identity

* `componentversion::get_file_name()` returns the base name without extension (`foo_jl_spectrum`). Built in components return `Core`. The same string is the `user-components/<name>` directory and the bundle `<name>.component`.
* The version `componentversion` reports comes from `DECLARE_COMPONENT_VERSION` inside the binary, not from `Info.plist`. Editing `CFBundleShortVersionString` does not change what the Components page shows.
* `core_api::get_my_full_path()` returns the bundle path (`<profile>/user-components/<name>/<name>.component`), not the binary path the SDK comment describes. `user-components` is two directories up.
* foobar2000 loads `<dir>/<dir>.component` and ignores other directory names, so a backup next to a component is never loaded.

## Pending directory (used from 0.2.0)

* A third party component can stage an install or update in `user-components/pending/<name>/<name>.component`. An empty file `pending/<name>` is an uninstall marker.
* It is applied at the next start, before components load: the old directory is deleted and the staged directory is renamed into place. Nothing is applied at shutdown, and installing does not restart foobar2000.
* A kill at any point of the apply step is finished by the next start.
* foobar2000 writes the binary without the execute bit and it still loads.

## Restart and install (used from 0.2.0)

* `standard_commands::main_restart()` relaunches foobar2000 on Mac: the process ends, a new one (new pid) starts by itself and applies `pending/` before the components load. The call does not come back to its caller. Values written to `fb2k::configStore` just before it are kept. Measured with foobar2000 2.26.
* The install is one `rename()` of `<profile>/foo_component_updater_mac/work/<random>/stage/<name>` to `pending/<name>` (same volume), after the verified bundle was prepared there, so foobar2000 never sees a half written `pending/<name>`.
* `SecStaticCodeCheckValidity` with `kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode` accepts the foo_abx 2.2.3 package (Developer ID, Team ID 9UF72C5LAW, an extra `Contents/CodeResources` file) and ad hoc signed bundles, and rejects a bundle whose binary was changed after signing.
* `ditto -x -k` restores symlink entries of a zip made by `zip -y` or `ditto -c -k` as real links, including links that point outside the bundle (`/etc`), so the link walk after extraction is a live check. With a zip whose later entry lies below a link entry, ditto stopped with "Not a directory" and wrote nothing outside the target folder.
* `ditto -x -k` does not stop at the sizes in the central directory that the layout check reads: a zip whose directory announced 1000 bytes for an entry whose local header and deflate stream held 700 MB wrote the 700 MB file, at about 2 GB/s on an SSD. The declared sizes therefore bound nothing; the updater polls the size of the extraction folder every 100 ms and kills ditto (SIGKILL) once a poll finds more than 512 MB. That is a threshold, not a hard limit: ditto keeps writing between polls, and the batch saw 550 to 670 MB on disk before the kill (a reviewer measured about 768 MB with AppleDouble files).
* By default `ditto -x -k` also turns AppleDouble entries (`__MACOSX/._name`) into resource forks and extended attributes of the files they belong to: a zip with a 300 MB fork came out as a 300 MB file plus a 300 MB fork, and only the file shows in `st_size`. The updater extracts with `--norsrc --noextattr`, so the AppleDouble entries arrive as plain files, which the size poll counts. The foo_abx catalog package, the JendaT spectrum package and this component's own package extract to identical trees with and without the two options and pass `codesign --verify --strict --deep`.
* `ditto -x -k` creates folders as `drwx------` and applies the modes of the zip's folder entries only when it is done: a folder entry of mode 0300 was readable by its owner while a 3 GB file below it was written, and `d-wx------` afterwards. The size poll therefore sees a folder it cannot read only after ditto exited, but it refuses (and kills ditto) whenever its walk meets one or fails otherwise, because the total would be partial.
* The Team ID field of a signature proves nothing by itself: an ad hoc signature can carry any string there (the code directory's `teamOffset` is not covered by any certificate), and it passes `codesign --verify --strict`. The Team ID rule therefore uses the requirement `anchor apple generic and certificate leaf[subject.OU] = "<team>"`, which an ad hoc signature cannot satisfy. The batch builds such a forged package.
* A Restore Previous of an ad hoc backup over a Developer ID bundle is refused by the Team ID rule; the batch builds both versions with the same kind of signature.

## Signing and quarantine

* Ad hoc signed bundles load, because foobar2000 has `com.apple.security.cs.disable-library-validation`. Unsigned bundles do not load.
* A bundle with `com.apple.quarantine` does not load, delays startup to about 12 seconds and makes macOS show a "Not Opened" dialog on every start. Files downloaded with `NSURLSession` inside foobar2000 carry no quarantine attribute.

## Downloaded packages and quarantine

* A `.fb2k-component` downloaded with Safari carries `com.apple.quarantine` (`0083;...;Safari`).
* Installing that file through Settings > Components (the `+` button) produced a bundle without any quarantine attribute. It loaded, and the mapped binary matched the release SHA256 `6f517079b7f2fc311ffb1e614e86bd2aa7d0d5caea81523d3ebc3fd07c90e691`. There was no Gatekeeper dialog and no AppleSystemPolicy rejection. amfid logs its usual "adhoc signed" notice, as it does for every ad hoc signed component.
* Contrast with "Signing and quarantine" above: a quarantined bundle placed directly into `user-components` is rejected and triggers the "Not Opened" dialog.
* Tested 2026-10-21 with foobar2000 2.26 on macOS 26.

## HTTP

* `http_client` exists on Mac and handles HTTPS, redirects and custom headers, but reading the body of a `304` response blocks for tens of seconds. This component uses `NSURLSession` behind `fcu::httpGet` and never `http_client`.
* GitHub counts an unauthenticated `304` against the rate limit like any other request, so no ETag caching is used.
* GitHub rate limit answers are `403` or `429` with `x-ratelimit-remaining: 0` and `x-ratelimit-reset`, or with `Retry-After`. A `403` without those headers is a plain error.
* The official catalog answers an unknown component with HTTP 200 and the text "No such component.", not a 404. The parser treats both as "not in the catalog".
* sourceforge.net answers a Cloudflare challenge to unusual clients (`403`); the upstream parser is unchanged and an unreachable feed shows as an Error row.

## Configuration

* On Mac the SDK compiles `cfg_bool`, `cfg_int` and `cfg_string` as `cfg_var_modern`, which reads and writes `fb2k::configStore` (`SDK/cfg_var.cpp`). The values live in `config.sqlite` under `cfg_var.<GUID>` and persist across restarts (verified in the M1 batch). Upstream's cfg code needs no change.
* `FOOBAR2000_HAVE_CFG_VAR_LEGACY` is not defined: the prebuilt SDK libraries were compiled without it, and the legacy class layout differs.
* Config keys that need no GUID, such as the debug keys, are plain `configStore` strings.

## Build

* Do not define `DEBUG` or `_DEBUG` when linking the prebuilt Release SDK libraries: pfc then compiles `PFC_ASSERT` into calls to `pfc::myassert`, which the libraries do not contain, and the link fails. The Debug configuration defines `FCU_DEBUG_HOOKS=1` instead. `NDEBUG=1` is defined in both configurations to silence the pfc "release build without NDEBUG" message.
* The SDK static libraries are universal (arm64 and x86_64); the component is built for both in Release. Debug builds the same, which is why the log shows both architectures.

## Upstream diff

Baseline: `p2ashiura/foo_component_update_checker@e9015e2f5c9406c6a4d1f2c79b97e33b6270b28c` (v2.3.0), see `UPSTREAM`. Merge an upstream fix with a three way merge against that commit. Every change is mechanical:

All files:

* The UTF-8 byte order mark at the start of each file is removed.
* `#include "SDK-2025-03-07/foobar2000/SDK/foobar2000.h"` becomes `#include "../fb2k_sdk.h"`.

`remote_registry.cpp`:

* Includes `../Platform/fcu_http.h`.
* The `http_client` request is replaced by `fcu::httpGet(fcu::endpoint(k_remoteRegistryUrl, "/registry/known_components.json"), {}, abort)`. `fcu::endpoint` returns the URL unchanged in Release builds.
* The entries are deserialized by a new `parseEntries` before the cache is replaced, so a download with a wrong typed field keeps the previous cache. The same function reads the cache.

`repository_mapping.cpp`, `repository_mapping.h`, `remote_registry.h`, `automatic_check.h`: include path only (or nothing).

`automatic_check.cpp`:

* `result_window.h` becomes `../UI/ResultsWindow.h`.
* `Sleep(k_startupDelaySeconds * 1000)` becomes an abortable `fb2k::mainAborter().sleep_ex(k_startupDelaySeconds)`.
* The window call drops the `HWND` argument.
* `fb2k::inCpuWorkerThread` becomes `fb2k::splitTask` for the startup delay and for the check, so the long network work does not occupy the shared CPU worker pool. Abort checks and the main thread enumeration are kept.
* The result window call is `DeliverCheckResults(checkId, results, message, openIfClosed)`, called for every automatic check. Manual and automatic checks share one delivery path keyed by `CurrentUpdateCheckId()`: the window attached to that check receives the results, a window closed during an automatic check does not get recreated by it, and the notification level only decides whether a closed window opens.
* The check lambda has a `try` / `catch (std::exception const&)` so nothing escapes into foobar2000.
* The due test is `fcu::isAutomaticCheckDue` (pure, unit tested) and the check body is `EvaluateAutomaticCheck()`, called on the main thread by the startup delay and by the 6 hour timer in `Integration/PeriodicCheck.mm`. It refuses to start while a check runs (`TryBeginUpdateCheck`) or the results window is open, and writes the last run time when the check starts instead of when it ends.
* Upstream records the last run only for automatic checks. Here every completed check (manual from the Help menu or the window, automatic) records it through `MarkCheckCompletedNow()`, and the interval of the automatic check counts from it. The automatic check still also writes it when it starts.
* `automatic_check.h` and `.cpp` gain `GetAutomaticCheckLastRun()`, a read only accessor for the persisted last run time (shown on the preferences page).
* Debug builds only: `on_init` schedules nothing while the autotest config key is set (the saved preference is not touched).

`update_check.h`:

* `UpdateStatus` moves to `update_parse.h` and gains `NoSource`.
* `InstalledComponentInfo` gains `hasBundleSource` and `bundleSourceJson`; `CheckResult` gains `downloadUrl`, `assetName`, `sourceOrigin`, `sourceLabel` and `note`.
* `RunUpdateCheck` gains an optional progress callback.
* Every source entry is checked by `validateSourceFields` before a URL is built from it, whichever list it came from; failures become "Invalid source" rows.
* `PrintUpdateCheckResults` is removed (unused upstream outside the removed menu command).

`update_check.cpp`:

* `RunUpdateCheck` is an exception boundary around the work: any `std::exception` ends as an Error row. A registry error is reported whenever the registry status carries one, not only when a fetch was attempted.

* `compareVersions` and its helpers move verbatim to `update_parse.cpp`.
* The GitLab, Codeberg, marc2k3, SourceForge and hyv fetchers keep their request URLs; the HTTP call becomes `fcu::httpGet` and the parsing after it moves verbatim to `ParseGitLabRelease`, `ParseCodebergRelease`, `ParseMarc2k3Page`, `BuildSourceForgeRssUrl`, `ParseSourceForgeFeed` and `ParseHyvPage` in `update_parse.cpp`. The GitLab release URL is built with `std::string` instead of `pfc::string8`.
* `FetchGitHubLatestRelease` (`/releases/latest`) is replaced by `Core/github_releases` (one `/releases` request per repository, selection by package file name).
* Source resolution is `Core/source_resolution` (user mappings, `Info.plist` key, registry, built in list, catalog) instead of the two lookups.
* Components without a source are listed as `NoSource` instead of skipped.
* The `mainmenu_commands` class moves to `Integration/Main.mm`.

Not ported: `result_window.cpp`, `preferences_page.cpp`, `repository_mapping_ui.cpp`, `dllmain.cpp`. They are replaced by `UI/` and `Integration/Main.mm`.

`third_party/nlohmann/json.hpp` is unchanged.

One upstream behaviour kept on purpose: `compareVersions` reads `1.2.` as `1.2` because `getline` drops the empty token after a trailing dot. A test records it.
