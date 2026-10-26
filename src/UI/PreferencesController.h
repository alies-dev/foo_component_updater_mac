#pragma once

#import <Cocoa/Cocoa.h>

#include "../version.h"

NS_ASSUME_NONNULL_BEGIN

@interface FCUPreferencesController : NSViewController

#ifdef FCU_DEBUG_HOOKS
- (NSString *)debugLastCheckText;
- (NSString *)debugGeometry;
- (NSView *)debugUpdatesView;
- (NSInteger)debugTypeInterval:(NSString *)text;
- (NSInteger)debugTypeThenStep:(NSString *)text direction:(NSInteger)direction;
- (NSString *)debugIntervalFieldText;
- (NSString *)debugShownGeometry;
- (NSString *)debugShownGeometryNumbers;
- (void)debugClosePreferencesWindow;
#endif

@end

#ifdef FCU_DEBUG_HOOKS
// Autotest: geometry of the preferences page shown in the real Preferences window, "page WxH in superview WxH,
// updates WxH"; "" when none is shown. The Numbers variant is "pageW pageH superW superH updatesH".
NSString *FCUDebugShownPreferencesGeometry(void);
NSString *FCUDebugShownPreferencesNumbers(void);
// Performs close on the window holding the shown page (no-op when none).
void FCUDebugClosePreferencesWindow(void);
#endif

// Opens or closes the help popover below `anchor`.
void FCUShowHelpPopover(NSView *anchor);

// Content view of the help popover, for off screen rendering in the Debug autotest.
NSView *FCUMakeHelpContentView(void);

NS_ASSUME_NONNULL_END
