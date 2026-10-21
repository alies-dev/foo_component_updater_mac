#pragma once

#include "../version.h"

// Re-evaluates the automatic check every 6 hours while foobar2000 runs (main thread
// timer, invalidated on quit). The startup evaluation lives in automatic_check.cpp.

#ifdef FCU_DEBUG_HOOKS
// Autotest only: starts the timer with the period of foo_component_updater_mac.debug.recheck_seconds.
void DebugStartPeriodicCheck();
// Timer firings since start.
int DebugPeriodicTicks();
#endif
