# Making your component updatable

This updater finds new versions of third party foobar2000 components. These guidelines make yours easy to find and compare.

## Publish on GitHub

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

## Or publish in the official catalog

Components listed on foobar2000.org with macOS under "Supported system" or "Supported systems" are found by file name without any of the above, from `https://www.foobar2000.org/components/view/<file name>`.

The catalog is also the next step when a GitHub source from the registry, the built in list or `FB2KUpdateSource` has no release with a matching package: the updater then checks the catalog page of the same component.

## Order of lookup

The first match wins:

1. The `FB2KUpdateSource` key in the component's `Info.plist` (this page).
2. The shared registry of p2ashiura (`known_components.json`, refreshed at most once a day).
3. A short built in list: the `foo_jl_*` components by JendaT and a few other GitHub components (`foo_mac_scrobble`, `foo_vis_projectm_mac`, `foo_cyan_leaf`, `foo_vis_projectMacOS`, `foo_richtext_mac`).
4. The official foobar2000.org component catalog, for components that list macOS support. Also used when step 1, 2 or 3 points at GitHub but no release has a matching package.
