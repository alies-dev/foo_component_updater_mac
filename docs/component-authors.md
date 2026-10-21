# Making your component updatable

This updater finds new versions of third party foobar2000 components. These guidelines make yours easy to find and compare.

## Publish on GitHub

1. Publish a GitHub Release and attach the package, a `.fb2k-component` file.
2. Name the package exactly `<file name>.fb2k-component`, where `<file name>` is what the Components page shows in the Module column (`foo_example` for `foo_example.component`). The updater picks the newest release that has an asset with this name, so a repository that holds several components works, and tag prefixes do not matter.
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

Components listed on foobar2000.org with macOS under "Supported systems" are found by file name without any of the above, from `https://www.foobar2000.org/components/view/<file name>`.

## Order of lookup

The first match wins:

1. Your own mappings (Preferences, Custom sources, see [custom-sources.md](custom-sources.md)).
2. The `FB2KUpdateSource` key in the component's `Info.plist` (this page).
3. The shared registry of p2ashiura (`known_components.json`, refreshed at most once a day).
4. A short built in list of the `foo_jl_*` components by JendaT.
5. The official foobar2000.org component catalog, for components that list macOS support.
