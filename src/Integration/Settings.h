#pragma once

// Settings that upstream does not have. Stored in foobar2000's config like
// upstream's cfg_bool/cfg_int values (see automatic_check.h).
bool GetIncludePrereleases();
void SetIncludePrereleases(bool enabled);

// Results window: list the built in components (file name "Core"). Off by default.
bool GetShowBuiltInComponents();
void SetShowBuiltInComponents(bool enabled);
