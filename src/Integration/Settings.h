#pragma once

#include <string>

// Settings that upstream does not have. Stored in foobar2000's config like
// upstream's cfg_bool/cfg_int values (see automatic_check.h).
bool GetIncludePrereleases();
void SetIncludePrereleases(bool enabled);

// Results window: list the built in components (file name "Core"). Off by default.
bool GetShowBuiltInComponents();
void SetShowBuiltInComponents(bool enabled);

// Components the user keeps although a replacement is declared (results window, row menu).
// The pair is remembered, so a different replacement is offered again. Any thread.
bool IsReplacementKept(std::string const& oldName, std::string const& newName);
void SetReplacementKept(std::string const& oldName, std::string const& newName, bool kept);
