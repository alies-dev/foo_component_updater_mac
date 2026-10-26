#pragma once

#include <string>
#include <vector>

#include "../upstream/update_check.h"
#include "../version.h"

#ifdef __OBJC__
#import <Cocoa/Cocoa.h>
// Posted on the main thread by DeliverCheckResults once the check has ended, so open UI can refresh.
extern NSNotificationName const FCUUpdateCheckCompletedNotification;

// The results table with its footer (Show built in components, status line, Install). It shows the process-wide
// model, so a page that is created again later shows what the last one did. Lives in the preferences page.
@interface FCUUpdatesView : NSView
#ifdef FCU_DEBUG_HOOKS
- (size_t)realiseAllCells;
- (size_t)visibleRowCount;
- (NSString *)debugLayout;
#endif
@end
#endif

// Main thread only.

// Help > Check for Component Updates... and Check Now: shows Preferences at our page
// (ui_control::get()->show_preferences(fcu::guid_preferences_page)) and starts a check, unless one is running,
// which the page then shows when it ends (no second check).
void ShowUpdatesPage();

// Delivers the results of check `checkId` (manual or automatic, see CurrentUpdateCheckId) to the model; the latest
// check wins. Ends the check exactly once. With openIfClosed (the automatic check's notification level) and the page
// not visible, shows the page, unless the user left the page while this very check ran.
void DeliverCheckResults(int64_t checkId, std::vector<CheckResult> const& results, const char* emptyMessage, bool openIfClosed);

// True while our preferences page is on screen.
bool IsUpdatesPageVisible();

// The preferences page reports when it appears and disappears.
void UpdatesPageVisibilityChanged(bool visible);

#ifdef FCU_DEBUG_HOOKS
// The autotest never opens Preferences: ShowUpdatesPage and the automatic popup only mark the page visible.
void DebugSetUpdatesPageOffscreen(bool offscreen);
// Like the user leaving the page.
void DebugHideUpdatesPage();
// Rows the page shows (-1 when not visible) and whether it waits for a check begun elsewhere.
long DebugUpdatesPageRows(bool* attached);
// The page's status line ("" when not visible), and a click on its "Show built in components" checkbox.
std::string DebugUpdatesStatus();
void DebugToggleBuiltIn();
// Title and enabled state of the "Restore Previous" context menu item of the row for component `name` ("" when no such row).
std::string DebugRestoreMenuItem(std::vector<CheckResult> const& results, std::string const& name, bool* enabled);
// Widths of the page view, scroll view, table and columns as of the last snapshot.
std::string DebugLastUpdatesLayout();
// Builds the page off screen with these results and creates every table cell, so the autotest exercises the
// table code without showing any UI. Returns the cell count (5 per visible row).
size_t DebugRealiseUpdatesTable(std::vector<CheckResult> const& results, size_t* visibleRows);

// Renders the whole preferences page (settings and table) off screen at 720 x 560 in light mode, with built in
// components shown or hidden, ticks the first installable row and writes a PNG. Returns the number of visible rows
// (-1 when the file could not be written).
long DebugSnapshotUpdatesPage(std::vector<CheckResult> const& results, bool showBuiltIn, const char* pngPath);

// Ticks the first installable row and renders the switch confirmation it would ask for (PNG); returns its title, text
// and links ("" when that row is no switch).
std::string DebugSnapshotSwitchConfirmation(std::vector<CheckResult> const& results, const char* pngPath);
#endif
