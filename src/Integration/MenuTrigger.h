#pragma once

#include "../version.h"

#ifdef FCU_DEBUG_HOOKS
// Autotest only: how many menu notifications started or forwarded a check.
int DebugMenuTriggersHandled();
#endif
