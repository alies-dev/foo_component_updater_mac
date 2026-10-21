#pragma once

#import <Cocoa/Cocoa.h>

#include "../version.h"

NS_ASSUME_NONNULL_BEGIN

@interface FCUPreferencesController : NSViewController

// Validates `text` as the Sources JSON and saves it. On failure the saved value
// is kept and `message` explains why. Used by the Apply button.
- (BOOL)applySourcesText:(NSString *)text message:(NSString * _Nullable * _Nullable)message;

#ifdef FCU_DEBUG_HOOKS
- (void)debugExpandAdvanced;
- (NSString *)debugGeometry;
- (NSInteger)debugTypeInterval:(NSString *)text;
- (NSInteger)debugTypeThenStep:(NSString *)text direction:(NSInteger)direction;
- (NSString *)debugIntervalFieldText;
- (NSString *)debugInsertExample:(BOOL *)enabledWhenEmpty enabledWhenFilled:(BOOL *)enabledWhenFilled;
#endif

@end

// Opens or closes the help popover below `anchor`.
void FCUShowHelpPopover(NSView *anchor);

// Content views of the popovers, for off screen rendering in the Debug autotest.
NSView *FCUMakeHelpContentView(void);
NSView *FCUMakeSourcesHelpContentView(void);

NS_ASSUME_NONNULL_END
