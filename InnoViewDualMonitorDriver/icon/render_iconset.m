// Renders the SVG app icon into an .iconset directory for iconutil.
// AppKit reads SVG by itself, so no extra tools are needed.
//   render_iconset AppIcon.svg out.iconset
#import <AppKit/AppKit.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3) {
            fprintf(stderr, "usage: %s icon.svg out.iconset\n", argv[0]);
            return 2;
        }
        NSImage *svg = [[NSImage alloc] initWithContentsOfFile:@(argv[1])];
        if (!svg) {
            fprintf(stderr, "cannot read %s\n", argv[1]);
            return 1;
        }
        NSString *dir = @(argv[2]);
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES
                                                attributes:nil error:NULL];

        static const int sizes[] = {16, 32, 128, 256, 512};
        for (size_t i = 0; i < sizeof sizes / sizeof sizes[0]; i++) {
            for (int scale = 1; scale <= 2; scale++) {
                int px = sizes[i] * scale;
                NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
                    initWithBitmapDataPlanes:NULL pixelsWide:px pixelsHigh:px bitsPerSample:8
                             samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                              colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
                rep = [rep bitmapImageRepByRetaggingWithColorSpace:NSColorSpace.sRGBColorSpace];

                [NSGraphicsContext saveGraphicsState];
                NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
                NSGraphicsContext.currentContext.imageInterpolation = NSImageInterpolationHigh;
                [svg drawInRect:NSMakeRect(0, 0, px, px) fromRect:NSZeroRect
                      operation:NSCompositingOperationCopy fraction:1];
                [NSGraphicsContext restoreGraphicsState];

                NSString *name = scale == 1
                    ? [NSString stringWithFormat:@"icon_%dx%d.png", sizes[i], sizes[i]]
                    : [NSString stringWithFormat:@"icon_%dx%d@2x.png", sizes[i], sizes[i]];
                NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                if (![png writeToFile:[dir stringByAppendingPathComponent:name] atomically:YES]) {
                    fprintf(stderr, "cannot write %s/%s\n", argv[2], name.UTF8String);
                    return 1;
                }
            }
        }
    }
    return 0;
}
