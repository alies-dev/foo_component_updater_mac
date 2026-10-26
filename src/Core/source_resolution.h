#pragma once

#include <string>
#include <vector>

#include "github_releases.h"
#include "../upstream/repository_mapping.h"

namespace fcu {

enum class SourceOrigin { None, InfoPlist, Registry, BuiltIn, Catalog };

// Label shown in the Source column.
char const* originLabel(SourceOrigin origin);

struct ResolvedSource {
    SourceOrigin origin = SourceOrigin::None;
    RepositoryMappingEntry entry; // source "catalog" for SourceOrigin::Catalog
    std::string note;             // row tooltip, e.g. an ignored invalid FB2KUpdateSource
    std::string invalid;          // why the matched entry cannot be used; no URL may be built from it
};

struct BundleSource {
    bool present = false; // the Info.plist has an FB2KUpdateSource key
    std::string json;     // the dictionary as JSON
};

struct SourceLists {
    std::vector<RepositoryMappingEntry> registry;
    std::vector<RepositoryMappingEntry> builtIn;
};

// Registry format ({"schema_version":1,"components":[{"dll","source","owner","repo","url"}]}).
// Entries without dll or source are dropped, as upstream does.
bool parseRegistryJson(std::string const& text, std::vector<RepositoryMappingEntry>& out);

// First match wins: Info.plist key, remote registry, built in list, official
// catalog. "Core" components get none.
ResolvedSource resolveSource(std::string const& fileName, BundleSource const& bundle, SourceLists const& lists);

// Whether a GitHub check that ended with this outcome continues with the catalog:
// only when no release has a matching package. Incomplete and failed checks keep
// their result.
bool fallsThroughToCatalog(SourceOrigin origin, AssetOutcome::Kind outcome);

} // namespace fcu
