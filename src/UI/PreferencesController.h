#pragma once

#import <Cocoa/Cocoa.h>

#include "../version.h"

NS_ASSUME_NONNULL_BEGIN

@interface FCUPreferencesController : NSViewController

#ifdef FCU_DEBUG_HOOKS
- (NSString *)debugLastCheckText;
- (NSString *)debugGeometry;
- (NSInteger)debugTypeInterval:(NSString *)text;
- (NSInteger)debugTypeThenStep:(NSString *)text direction:(NSInteger)direction;
- (NSString *)debugIntervalFieldText;
#endif

@end

// Opens or closes the help popover below `anchor`.
void FCUShowHelpPopover(NSView *anchor);

// Content view of the help popover, for off screen rendering in the Debug autotest.
NSView *FCUMakeHelpContentView(void);

NS_ASSUME_NONNULL_END
