#pragma once

#include <string>

// Where a component (by file name) gets its updates. Info.plist, the remote
// registry, the built in list and the official catalog all produce this form.

struct RepositoryMappingEntry {
    std::string dllName;  // With or without ".dll"; normalized before comparing.
    std::string source;   // "github" / "gitlab" / "codeberg" / "marc2k3" / "sourceforge" / "hyv",
                          // or "catalog" for the official catalog.
    std::string owner;    // github, gitlab and codeberg only; empty for url sources.
    std::string repo;     // github, gitlab and codeberg only; empty for url sources.
    std::string url;      // marc2k3, sourceforge and hyv only: the https URL of the component's
                          // page, kept as is. Empty for github, gitlab and codeberg.
};
