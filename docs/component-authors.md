# Making your component updatable

This updater finds new versions of third party foobar2000 components. These guidelines make yours easy to find and compare.

## Recommended: get listed in the official repository

foobar2000 has an official component repository, [foobar2000.org/components](https://www.foobar2000.org/components/system/mac), with a macOS section. To get a component listed there, register on the Hydrogenaudio forum and contact [Peter](https://hydrogenaud.io/index.php?action=profile;u=84), the foobar2000 developer, with information about your component ([foobar2000 developer documentation](https://www.foobar2000.org/RTFM), "Getting a component listed on foobar2000.org/components").

A listing reaches everyone who browses the repository, and this updater needs nothing else: it finds a listed component by its file name at `https://www.foobar2000.org/components/view/<file name>` when the listing names macOS under "Supported system" or "Supported systems", compares the version shown there with the installed one and installs the package from it. Keep the version on the listing equal to `DECLARE_COMPONENT_VERSION`, and the package in the layout described below (`mac/<file name>.component`, signed, same `CFBundleIdentifier` as before).

## Fallback: publish on GitHub

For components that are not in the official repository (yet), or whose updates appear on GitHub first, the updater reads GitHub releases. Together with the `FB2KUpdateSource` key below this needs nobody's list:

1. Publish a GitHub Release and attach the package, a `.fb2k-component` file.
2. Name the package `<file name>.fb2k-component`, where `<file name>` is what the Components page shows in the Module column (`foo_example` for `foo_example.component`). That exact name is always preferred. The updater also accepts `<file name>` followed by an optional version and any of `macos`, `mac`, `arm64`, `universal`, separated by `-` or `_` and in any letter case (`foo_example-macos.fb2k-component`, `foo_example-1.2.0-macos-arm64.fb2k-component`), and a `.zip` of that form (`foo_example-v1.2.0.zip`), although a zip is only reported and never installed. Anything else after the name, such as `-bin`, `-win32` or `_extra`, is not a match, so `foo_example` never picks up `foo_example_extra`.
   To be installed the package must hold `mac/<file name>.component/Contents/Info.plist` and a file in `Contents/MacOS/` (files for other platforms beside `mac/` are ignored), be signed (ad hoc is enough) and keep the `CFBundleIdentifier` of the installed version; when the installed version is signed with a Developer ID, the new one needs the same Team ID.
   The newest release with a matching asset is used, so a repository that holds several components works and tag prefixes do not matter. When that release has several equally good matches (for example `-macos` and `-arm64`), the check fails with an error instead of guessing; keep one macOS package per release.
3. Use the same version in the tag and in `DECLARE_COMPONENT_VERSION`. Tags are read like this: the whole tag when it is a valid version with an optional `v` (`v1.2.0`, `1.2.0`), otherwise the text after a `-v` that forms a complete valid version (`example-v1.2.0`). Anything else is shown as "Unable to compare".
4. Mark test builds as prereleases. They are ignored unless the user turns on "Include prereleases".
5. Keep the package layout `mac/<file name>.component` with an ad hoc signature (`codesign --force --sign - <file name>.component`). A package may also hold Windows files next to `mac/`.
6. Use plain numeric versions with an optional prerelease and build part: `1.2.3`, `1.2.3-beta.1`, `1.2.3+5`. Versions that do not fit are shown as "Unable to compare" instead of guessing.

## Declare where updates live: `FB2KUpdateSource`

A convention of this project, modelled on Sparkle's `SUFeedURL`. Add a dictionary to your component's `Info.plist` and no registry entry is needed:

```xml
<key>FB2KUpdateSource</key>
<dict>
    <key>source</key><string>github</string>
    <key>owner</key><string>your-name</string>
    <key>repo</key><string>foo_example</string>
</dict>
```

Rules:

* `source` is one of `github`, `gitlab`, `codeberg`, `marc2k3`, `sourceforge`, `hyv`.
* `github`, `gitlab` and `codeberg` take `owner` and `repo`, both matching `[A-Za-z0-9._-]+`. The other three take `url`, which must start with `https://`.
* No other keys are allowed, and `dll` is not used: the component name is already known.
* An invalid value is ignored, the next source is tried, and the results window says "Invalid FB2KUpdateSource" in the row tooltip.
* The key only affects the bundle that contains it. It takes effect from the first release that includes it, so older installed versions are found through the registry.

## When the official repository is checked

Without any of the above, a component listed in the official repository is found there by file name. The repository is also the next step when a GitHub source from the registry, the built in list or `FB2KUpdateSource` has no release with a matching package: the updater then checks the listing of the same component.

## Order of lookup

The first match wins:

1. The `FB2KUpdateSource` key in the component's `Info.plist` (this page).
2. The shared registry of p2ashiura (`known_components.json`, refreshed at most once a day).
3. A short built in list: the `foo_jl_*` components by JendaT and a few other GitHub components (`foo_mac_scrobble`, `foo_vis_projectm_mac`, `foo_cyan_leaf`, `foo_vis_projectMacOS`, `foo_richtext_mac`).
4. The official foobar2000.org component catalog, for components that list macOS support. Also used when step 1, 2 or 3 points at GitHub but no release has a matching package.

## Point users to a successor: `FB2KReplacedBy`

When your component is superseded (renamed, merged into another one, taken over by a fork), ship one last release whose `Info.plist` names the successor:

```xml
<key>FB2KReplacedBy</key>
<dict>
    <key>component</key><string>foo_example_ng</string>
    <key>source</key><string>github</string>
    <key>owner</key><string>new-owner</string>
    <key>repo</key><string>foo_example_ng</string>
    <key>migration_url</key><string>https://github.com/new-owner/foo_example_ng#migrating</string>
</dict>
```

Rules:

* `component` is required, unless foobar2000 itself replaced your component (see below): the successor's file name (letters, digits, `.`, `_`, `-`, `+`), not your own. `foobar2000` is not a valid component name here.
* `source`, `owner`, `repo` and `url` say where the successor's releases live and follow the `FB2KUpdateSource` rules above. Declare them: the successor is never looked up in the shared registry or the foobar2000.org catalog, because a list run by someone else must not decide which code your declaration installs. Only a successor that the updater's built in list knows can go without them; when the list knows it, the list's source is used even if you declare another one.
* `migration_url` is optional: an `https://` page (printable ASCII, no user name before the host) that tells users what to set up again, such as logging in once more. The confirmation shows it as a link, and after the restart that completes the switch foobar2000 offers it once. It opens only when the user clicks it.
* `team` is optional: the successor's Team ID (10 capital letters or digits). If your component is signed with a Developer ID, the successor must be signed by the same team unless `team` names another one. Ad hoc signed components have nothing to pin.
* No other keys are allowed. It is a separate key on purpose: `FB2KUpdateSource` accepts no other keys, and older versions of the updater would drop the whole update source.
* Once a user has that release, the results window shows the row as "Replaced" with the successor's version. Ticking it and clicking Install downloads the successor (same package rules as above, a valid signature and a bundle identifier) and removes your component at the next start of foobar2000. Users can keep yours instead (right click > Keep).
* Settings are not carried over; the successor has its own.
* An invalid key is ignored and the row tooltip says "Invalid FB2KReplacedBy".

The updater's built in list can declare the same for components whose author no longer ships releases (`"replaced_by"` with the same fields).

### When foobar2000 itself replaced your component

If a foobar2000 release now includes what your component did, declare the version instead of a successor:

```xml
<key>FB2KReplacedBy</key>
<dict>
    <key>foobar2000</key><string>2.27</string>
    <key>migration_url</key><string>https://example.org/foo_example#built-in</string>
</dict>
```

* Declare exactly one of `component` and `foobar2000`. With `foobar2000`, `source`, `owner`, `repo`, `url` and `team` are not allowed: there is nothing to download.
* `foobar2000` is the first foobar2000 version that includes the feature, in a form such as `2.27`. Anything else is an invalid key.
* `migration_url` is optional and works as above.
* When the running foobar2000 is that version or newer, the results window shows the row as "Replaced by foobar2000 2.27". Ticking it and clicking Install only removes your component at the next start of foobar2000; nothing is downloaded. Users can keep yours instead (right click > Keep).
* With an older foobar2000 the row is checked as usual and its note says that foobar2000 2.27 includes it and that it can be removed after updating foobar2000. It does not count as "Replaced" then.
* The updater's built in list accepts the same in `"replaced_by"`: `{"foobar2000": "2.27"}`.
