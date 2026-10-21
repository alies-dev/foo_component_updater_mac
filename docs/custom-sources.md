# Custom sources

Custom sources tell the updater where a component's author publishes new versions. You need one only when a component shows **No source** in the results window. Most components never need it: the updater already knows many of them from its built in list, the shared registry, the component's own `FB2KUpdateSource` key and the foobar2000.org catalog (see [the order of lookup](component-authors.md#order-of-lookup)).

The box is in Preferences, Tools, Component Updates, under **Custom sources**. Entries you save there come first: they win over every other source for the same component.

## Setup

1. Run a check (Check Now). Find a component marked **No source**. The name in brackets in the Component column, for example `foo_example`, is the `dll` of its entry. Names are compared in lower case and a trailing `.dll` is ignored.
2. Find where its author publishes releases: a GitHub, GitLab or Codeberg repository, or a SourceForge, marc2k3 or foobar.hyv.fi page.
3. Click **Insert Example** (it is enabled while the box is empty), or type an entry from this page, and edit it.
4. Click **Save Sources**. The button is enabled only when the text differs from what is saved. The next check uses the entries.

The box holds one JSON array. Separate several entries with commas inside the brackets. An empty box means no custom sources.

## Fields

| Field | Used by | Meaning |
| --- | --- | --- |
| `dll` | all | Component name, required. Letters, digits, `.`, `_`, `-` and `+` only. |
| `source` | all | `github`, `gitlab`, `codeberg`, `marc2k3`, `sourceforge` or `hyv`. Leave it out and `github` is used. |
| `owner`, `repo` | `github`, `gitlab`, `codeberg` | Account and repository, each with letters, digits, `.`, `_` and `-` only. For github.com/author/foo_example, owner is `author` and repo is `foo_example`. GitLab subgroups (a slash in the owner) are not supported. |
| `url` | `marc2k3`, `sourceforge`, `hyv` | Page of the component, starting with `https://`. |

Other fields are rejected. The two groups do not mix: a repository source with a `url`, or a page source with `owner` or `repo`, is an error.

## Examples

### github

The newest release (not a draft, and not a prerelease unless you turned prereleases on) that carries a package for `<dll>` is used. A package is `<dll>.fb2k-component` (preferred), or `<dll>` plus an optional version and `macos`, `mac`, `arm64` or `universal`, separated by `-` or `_`, ending in `.fb2k-component` or `.zip` (`foo_example-macos.fb2k-component`, `foo_example-v1.2.0.zip`). Names like `foo_example-bin.zip`, `foo_example-win32.fb2k-component` or `foo_example_extra.fb2k-component` do not match. Within one release the exact name wins, then a platform suffix, then `.fb2k-component` over `.zip`; equally good matches are an error. A GitHub mapping you enter yourself never falls back to the catalog. The version is read from the release tag: the whole tag when it is a version such as `v1.2.0`, otherwise the part after `-v` as in `spectrum-v1.2.0`.

```json
[{ "dll": "foo_example",
   "source": "github",
   "owner": "author",
   "repo": "foo_example" }]
```

### gitlab

The latest release of the project is used, and its tag is the version.

```json
[{ "dll": "foo_example",
   "source": "gitlab",
   "owner": "author",
   "repo": "foo_example" }]
```

### codeberg

The newest release that is not a draft or a prerelease is used, and its tag is the version.

```json
[{ "dll": "foo_example",
   "source": "codeberg",
   "owner": "author",
   "repo": "foo_example" }]
```

### sourceforge

Use the address of the project's folder in the Files tab. The updater reads that folder's feed and takes the newest file whose name ends in `-<version>.zip`, `.rar`, `.7z` or `.fb2k-component`, for example `foo_input_sacd-2.0.25.zip`. Files such as `readme.txt` or `foo_input_sacd-2.0.25_for_foobar-1.6.x.zip` are skipped.

```json
[{ "dll": "foo_input_sacd",
   "source": "sourceforge",
   "url": "https://sourceforge.net/projects/sacddecoder/files/foo_input_sacd/" }]
```

### marc2k3

For components on marc2k3.github.io. The version is read from the file name of the page's Download button, such as `foo_cover_utils-1.8.fb2k-component`.

```json
[{ "dll": "foo_cover_utils",
   "source": "marc2k3",
   "url": "https://marc2k3.github.io/component/cover-utils/" }]
```

### hyv

For components on foobar.hyv.fi. The version is read from the `Version:` row of the page.

```json
[{ "dll": "foo_hdcd",
   "source": "hyv",
   "url": "https://foobar.hyv.fi/?view=foo_hdcd" }]
```

### Several entries

```json
[{ "dll": "foo_example",
   "source": "github",
   "owner": "author",
   "repo": "foo_example" },
 { "dll": "foo_hdcd",
   "source": "hyv",
   "url": "https://foobar.hyv.fi/?view=foo_hdcd" }]
```

Each component may appear once.

## Errors when saving

A failed save shows **Not saved.** and the reason in red, and keeps the sources you saved before. Entry numbers start at 1.

| Message | Cause and fix |
| --- | --- |
| `Invalid JSON: ...` | The text is not valid JSON. Check commas between entries, quotes around every key and value, and the closing `]`. |
| `Expected a JSON array of objects, e.g. [...]` | The text is not a list. Wrap the entries in `[` and `]`. |
| `Entry 2: must be an object` | An item in the list is not `{ ... }`. |
| `Entry 2: unknown field "repos"` | A field name is misspelled. Use `dll`, `source`, `owner`, `repo` or `url`. |
| `Entry 2: "dll" is required` | Add the component name. |
| `Entry 2: "dll" may only contain letters, digits, '.', '_', '-' and '+'` | Use the name from the Component column, without a path or spaces. |
| `Entry 2: "source" must be a string` | Put the value in quotes, for example `"github"`. The same message appears for `dll`, `owner`, `repo` and `url` with their own name. |
| `Entry 2: unsupported source "svn" (use github, gitlab, codeberg, marc2k3, sourceforge or hyv)` | Pick one of the six sources. |
| `Entry 2: "owner" and "repo" are required for source "github" (letters, digits, '.', '_', '-')` | Add both, without slashes or spaces. Source `gitlab` and `codeberg` show their own name. |
| `Entry 2: "url" must be an https:// URL for source "hyv"` | Use a full address starting with `https://`. Sources `marc2k3` and `sourceforge` show their own name. |
| `Entry 2: source "github" takes "owner" and "repo", not "url"` | Remove `url`, or change the source to a page source. |
| `Entry 2: source "hyv" takes "url", not "owner" and "repo"` | Remove `owner` and `repo`, or change the source to a repository source. |
| `Entry 2: duplicate component "foo_example"` | Keep one entry per component. Names are compared in lower case, without `.dll`. |

## Errors in the results

A saved entry that cannot find a version shows **Error** with the reason as the tooltip of the row:

| Message | Cause and fix |
| --- | --- |
| `Repository or releases not found (HTTP 404)` | The owner or repo is wrong, or the repository is private. |
| `No release with this component's package was found.` | No release carries a package for `<dll>` as described under github. Check `dll`, or the author publishes under another name. |
| `Release v1.2.0 has several equally suitable packages for this component.` | That release has two matches of the same kind, for example `-macos` and `-arm64`. Ask the author to attach one. |
| `Invalid response: no releases found for this repository.` | The Codeberg repository has no published release. |
| `Unable to locate the download button on this page (page structure may have changed).` | The marc2k3 page is not a component page of that site. |
| `Unable to locate the Version field on this page (page structure may have changed).` | The hyv address is not a component page of that site. |
| `Invalid SourceForge URL: expected a project files page, e.g. https://sourceforge.net/projects/<project>/files/<folder>/` | Use the address of the Files tab folder. |
| `No release archive with a recognizable version number was found in this SourceForge folder's feed.` | The folder holds no file named like `name-1.2.3.zip`. |

When the version found is not a number the updater understands (for example `release-5`), the row says **Unable to compare** and shows that version as Latest.
