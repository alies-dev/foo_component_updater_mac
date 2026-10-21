#pragma once

#include <string>
#include <vector>

#include "../upstream/update_check.h"
#include "../version.h"

// Main thread only.

// Opens the results window (at most one) and starts a check of the installed components.
// With a window already open it is brought forward and a new check starts when none is
// running here; a check running elsewhere (the automatic one) is attached to instead.
void ShowUpdateResultWindow();

// Delivers the results of check `checkId` (manual or automatic, see CurrentUpdateCheckId).
// The window attached to that check shows them, whichever window instance it is. With no
// window, one opens only when openIfClosed is set (the automatic check's notification
// level) and the user has not closed the window of that very check; a window of another
// check is left alone (upstream's non intrusive rule).
void DeliverCheckResults(int64_t checkId, std::vector<CheckResult> const& results, const char* emptyMessage, bool openIfClosed);

// True while the results window exists.
bool IsResultsWindowOpen();

#ifdef FCU_DEBUG_HOOKS
// The autotest builds windows but never orders them onto the screen.
void DebugSetResultsWindowOffscreen(bool offscreen);
void DebugCloseResultsWindow();
// Rows of the open window (-1 when closed) and whether it waits for a background check.
long DebugResultsWindowRows(bool* attached);
// Status line of the open window ("" when closed), and a click on its "Show built in components" checkbox.
std::string DebugResultsStatus();
void DebugToggleBuiltIn();
// Widths of the window, scroll view, table and columns as of the last snapshot.
std::string DebugLastResultsLayout();
// Builds the window off screen, fills it and creates every table cell, so the
// autotest exercises the table code without showing any UI. Returns the cell count.
size_t DebugRealiseResultsWindow(std::vector<CheckResult> const& results, size_t* visibleRows);

// Renders the window content off screen in light mode, with built in components shown or hidden,
// and writes a PNG. Returns the number of visible rows (-1 when the file could not be written).
long DebugSnapshotResultsWindow(std::vector<CheckResult> const& results, bool showBuiltIn, const char* pngPath);
#endif
