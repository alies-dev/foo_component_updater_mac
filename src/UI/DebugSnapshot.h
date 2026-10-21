#pragma once

#include "../version.h"

#ifdef FCU_DEBUG_HOOKS

#import <Cocoa/Cocoa.h>

// Debug builds only: renders `view` off screen under the named appearance (for example
// NSAppearanceNameAqua or NSAppearanceNameDarkAqua) on the window background colour and
// writes a PNG. Nothing is shown on the desktop.
bool DebugWriteSnapshot(NSView *view, NSAppearanceName appearance, NSString *pngPath);

#endif
