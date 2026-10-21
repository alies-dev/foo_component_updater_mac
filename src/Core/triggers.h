#pragma once

#include <cstdint>
#include <string>

namespace fcu {

// Titles of foobar2000's own update menu items (verified in foobar2000 2.26): the app
// menu item and the Help menu item. Exact, case sensitive match; if foobar2000 renames
// them the trigger silently stops firing.
bool isCoreUpdateMenuTitle(std::string const& title);

// An automatic check is due when it is enabled and, if a check ever ran, at least
// intervalDays days have passed since the last check (any kind: manual, from the menus or
// automatic). A clock that went backwards (now before lastCheck) is never due.
// lastCheck <= 0 means never.
bool isAutomaticCheckDue(bool enabled, int64_t lastCheck, int intervalDays, int64_t now);

// What the interval field commits when editing ends: surrounding spaces are ignored, digits
// only, clamped to 1 to 30 (0 gives 1, 31 gives 30, a number too large for an int gives 30).
// Empty or non numeric text (including signs and decimals) reverts to `current`.
int parseIntervalInput(std::string const& text, int current);

} // namespace fcu
