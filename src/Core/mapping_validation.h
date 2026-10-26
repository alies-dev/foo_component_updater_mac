#pragma once

#include <string>

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

// Strict parse of an Info.plist FB2KUpdateSource dictionary (given as JSON):
// the fields source, owner, repo, url, "source" required. The entry gets dllName.
bool parseBundleSource(std::string const& dllName, std::string const& json,
                       RepositoryMappingEntry& out, std::string& error);

// The same rules for a source dictionary inside another key; `error` names no key.
bool parseSourceDictionary(std::string const& dllName, std::string const& json,
                           RepositoryMappingEntry& out, std::string& error);

} // namespace fcu
