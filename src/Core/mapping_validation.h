#pragma once

#include <string>
#include <vector>

#include "../upstream/repository_mapping.h"

namespace fcu {

// Lowercase, trailing ".dll" removed: the key used to match installed components.
std::string normalizeComponentName(std::string name);

bool isSupportedSource(std::string const& source);

// Fields a source needs before any URL is built from it: owner and repo matching
// [A-Za-z0-9._-]+ for github, gitlab and codeberg, an https:// url for the rest.
// Mixed fields (url with github, owner or repo with a url source) are rejected, so the
// source that is displayed is the one that is requested.
bool validateSourceFields(RepositoryMappingEntry const& entry, std::string& error);

// Strict parse of the Preferences "Sources" text: a JSON array of objects with
// the upstream fields dll, source, owner, repo, url. Blank text is an empty list.
// On failure `out` is untouched and `error` explains the first problem.
bool parseUserMappings(std::string const& text, std::vector<RepositoryMappingEntry>& out, std::string& error);

// The inverse of parseUserMappings, pretty printed, empty fields omitted.
std::string formatUserMappings(std::vector<RepositoryMappingEntry> const& entries);

// Strict parse of an Info.plist FB2KUpdateSource dictionary (given as JSON):
// the same fields minus "dll", "source" required. The entry gets dllName.
bool parseBundleSource(std::string const& dllName, std::string const& json,
                       RepositoryMappingEntry& out, std::string& error);

} // namespace fcu
