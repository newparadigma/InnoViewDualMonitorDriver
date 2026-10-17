// BGRA -> UYVY conversion (optionally rotated by 180 degrees) on the GPU.
// Same integer formulas as the NEON path in frame.c, so results are identical.
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "frame.h"

NS_ASSUME_NONNULL_BEGIN

@interface MSGPUConverter : NSObject

// nil if Metal is not available or the shader does not compile.
- (nullable instancetype)init;

// Shared CPU/GPU memory for the chip-format frame.
- (nullable id<MTLBuffer>)newFrameBufferWithLength:(size_t)length;

// Converts the given rects (frame coordinates, x and width even) of a BGRA
// frame into a w x h UYVY image in dst; with rotate, rect r lands at
// ms_rect_rot180(r). Blocks until the GPU is done.
- (BOOL)convert:(CVPixelBufferRef)frame
          rects:(const ms_rect *)rects
          count:(size_t)count
         rotate:(BOOL)rotate
             to:(id<MTLBuffer>)dst
          width:(int)w
         height:(int)h;

@end

NS_ASSUME_NONNULL_END
