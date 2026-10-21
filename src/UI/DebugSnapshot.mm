#include "DebugSnapshot.h"

#ifdef FCU_DEBUG_HOOKS

bool DebugWriteSnapshot(NSView *view, NSAppearanceName appearanceName, NSString *pngPath) {
    @autoreleasepool {
        NSAppearance *appearance = [NSAppearance appearanceNamed:appearanceName];
        view.appearance = appearance;
        if (view.window) view.window.appearance = appearance;
        [view layoutSubtreeIfNeeded];

        NSRect bounds = view.bounds;
        NSBitmapImageRep *probe = [view bitmapImageRepForCachingDisplayInRect:bounds];
        if (!probe) return false;

        // Draw straight into our own bitmap, on the window background colour of that appearance.
        NSBitmapImageRep *out = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nil
            pixelsWide:probe.pixelsWide pixelsHigh:probe.pixelsHigh bitsPerSample:8 samplesPerPixel:4
            hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        out.size = bounds.size;
        NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:out];
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = context;
        // Resolve the dynamic colour under the appearance first: a fill alone would use the app's.
        __block NSColor *background = nil;
        [appearance performAsCurrentDrawingAppearance:^{
            background = [NSColor.windowBackgroundColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        }];
        [background setFill];
        NSRectFill(NSMakeRect(0, 0, bounds.size.width, bounds.size.height));
        [NSGraphicsContext restoreGraphicsState];
        [view displayRectIgnoringOpacity:bounds inContext:context];

        NSData *png = [out representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        [[NSFileManager defaultManager] createDirectoryAtPath:pngPath.stringByDeletingLastPathComponent
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        return [png writeToFile:pngPath atomically:YES];
    }
}

#endif
