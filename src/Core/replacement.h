#pragma once

#include <map>
#include <string>
#include <vector>

#include "../upstream/repository_mapping.h"

namespace fcu {

// The component that took over from an installed one.
struct Replacement {
    std::string name;              // file name of the successor as declared (case kept, no ".dll"); compare normalized
    bool hasSource = false;        // where its updates live was declared with it
    RepositoryMappingEntry source; // when hasSource; source.dllName is the normalized name
    std::string migration;         // https page with migration notes, "" when none
    std::string team;              // Team ID the successor must be signed with, "" when not declared
};

// Strict parse of an FB2KReplacedBy dictionary (given as JSON): "component" required; optional
// source fields under the FB2KUpdateSource rules (all or nothing), "migration_url" (https URL) and
// "team" (10 character Team ID). Errors start "Invalid FB2KReplacedBy: ".
bool parseReplacedBy(std::string const& json, Replacement& out, std::string& error);

// Several components that do the same job; running two of them does it twice.
struct ComponentGroup {
    std::string title; // what each member is, singular ("Last.fm scrobbler")
    std::vector<std::string> members; // normalized file names
};

// The parts of the built in list (Resources/extra_components.json) besides the sources:
// "replaced_by" of the component entries (keyed by normalized file name) and "groups".
// Invalid entries are dropped, so a bad entry cannot reach a URL.
void parseBuiltInExtras(std::string const& text, std::map<std::string, Replacement>& replacements,
                        std::vector<ComponentGroup>& groups);

enum class ReplacementOrigin { None, InfoPlist, BuiltIn };

struct ReplacementLookup {
    ReplacementOrigin origin = ReplacementOrigin::None;
    Replacement replacement;
    std::string note; // row tooltip, e.g. an ignored invalid FB2KReplacedBy
};

// The component's own FB2KReplacedBy wins over the built in list; an invalid key is
// noted and the list is consulted. A component is never its own replacement.
ReplacementLookup findReplacement(std::string const& fileName, bool plistPresent, std::string const& plistJson,
                                  std::map<std::string, Replacement> const& builtIn);

// For each installed component in a group with other installed members, the tooltip
// naming them ("Same job as foo_b (Last.fm scrobbler). Keep only one."). Keyed by
// normalized file name; components without overlap are absent.
std::map<std::string, std::string> overlapNotes(std::vector<std::string> const& installedNames,
                                                std::vector<ComponentGroup> const& groups);

} // namespace fcu
