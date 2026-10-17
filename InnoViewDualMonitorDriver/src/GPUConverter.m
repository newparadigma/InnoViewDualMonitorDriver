#import "GPUConverter.h"

#include "log.h"

// One thread per output macropixel (two pixels). Fixed point Q14 as in
// frame.c; the chroma numerators get +128 << 15 so that only non-negative
// values are shifted.
static NSString *const kShaderSource = @R"(
#include <metal_stdlib>
using namespace metal;

struct Params { int src_x, src_y, dst_x, dst_y, w, h, rotate, stride; };

constant int YR = 4207, YG = 8260, YB = 1604;
constant int UR = -2428, UG = -4768, UB = 7196;
constant int VR = 7196, VG = -6026, VB = -1170;

kernel void bgra_to_uyvy(texture2d<float, access::read> src [[texture(0)]],
                         device uchar4 *dst [[buffer(0)]],
                         constant Params &p [[buffer(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    int ox = int(gid.x) * 2, oy = int(gid.y);
    if (ox >= p.w || oy >= p.h) return;
    int2 s0 = p.rotate ? int2(p.src_x + p.w - 1 - ox, p.src_y + p.h - 1 - oy) : int2(p.src_x + ox, p.src_y + oy);
    int2 s1 = s0 + int2(p.rotate ? -1 : 1, 0);
    int3 a = int3(rint(src.read(uint2(s0)).rgb * 255.0f));
    int3 b = int3(rint(src.read(uint2(s1)).rgb * 255.0f));
    int y0 = (YR * a.r + YG * a.g + YB * a.b + 8192) >> 14;
    int y1 = (YR * b.r + YG * b.g + YB * b.b + 8192) >> 14;
    int3 s = a + b;
    int u = (UR * s.r + UG * s.g + UB * s.b + (128 << 15) + 16384) >> 15;
    int v = (VR * s.r + VG * s.g + VB * s.b + (128 << 15) + 16384) >> 15;
    dst[(p.dst_y + oy) * p.stride + (p.dst_x + ox) / 2] =
        uchar4(uchar(clamp(u, 0, 255)), uchar(16 + y0), uchar(clamp(v, 0, 255)), uchar(16 + y1));
}
)";

typedef struct {
    int32_t src_x, src_y, dst_x, dst_y, w, h, rotate, stride;
} MSKernelParams;

@implementation MSGPUConverter {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLComputePipelineState> _pipeline;
    CVMetalTextureCacheRef _cache;
    CFAbsoluteTime _lastFlush;
}

- (nullable instancetype)init {
    if (!(self = [super init])) return nil;
    _device = MTLCreateSystemDefaultDevice();
    if (!_device) {
        msx_log("Metal: no device");
        return nil;
    }
    NSError *err = nil;
    id<MTLLibrary> lib = [_device newLibraryWithSource:kShaderSource options:nil error:&err];
    id<MTLFunction> fn = [lib newFunctionWithName:@"bgra_to_uyvy"];
    if (fn) _pipeline = [_device newComputePipelineStateWithFunction:fn error:&err];
    if (!_pipeline) {
        msx_log("Metal: shader failed: %s", err.localizedDescription.UTF8String);
        return nil;
    }
    _queue = [_device newCommandQueue];
    if (!_queue || CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, _device, NULL, &_cache) != kCVReturnSuccess) {
        msx_log("Metal: no command queue or texture cache");
        return nil;
    }
    msx_log("Metal: ready on %s", _device.name.UTF8String);
    return self;
}

- (void)dealloc {
    if (_cache) CFRelease(_cache);
}

- (nullable id<MTLBuffer>)newFrameBufferWithLength:(size_t)length {
    return [_device newBufferWithLength:length options:MTLResourceStorageModeShared];
}

- (BOOL)convert:(CVPixelBufferRef)frame
          rects:(const ms_rect *)rects
          count:(size_t)count
         rotate:(BOOL)rotate
             to:(id<MTLBuffer>)dst
          width:(int)w
         height:(int)h {
    if (count == 0) return YES;
    CVMetalTextureRef ct = NULL;
    if (CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _cache, frame, NULL, MTLPixelFormatBGRA8Unorm,
                                                  (size_t)w, (size_t)h, 0, &ct) != kCVReturnSuccess)
        return NO;
    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:_pipeline];
    [enc setTexture:CVMetalTextureGetTexture(ct) atIndex:0];
    [enc setBuffer:dst offset:0 atIndex:0];
    NSUInteger tw = _pipeline.threadExecutionWidth, th = MAX(1, _pipeline.maxTotalThreadsPerThreadgroup / tw);
    for (size_t i = 0; i < count; i++) {
        ms_rect r = rects[i], d = rotate ? ms_rect_rot180(r, w, h) : r;
        MSKernelParams p = {r.x, r.y, d.x, d.y, r.w, r.h, rotate, w / 2};
        [enc setBytes:&p length:sizeof p atIndex:1];
        [enc dispatchThreads:MTLSizeMake((NSUInteger)r.w / 2, (NSUInteger)r.h, 1)
            threadsPerThreadgroup:MTLSizeMake(tw, th, 1)];
    }
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    CFRelease(ct);
    // The cache frees textures of buffers no longer in use only when flushed.
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - _lastFlush >= 1.0) {
        CVMetalTextureCacheFlush(_cache, 0);
        _lastFlush = now;
    }
    return cb.status == MTLCommandBufferStatusCompleted;
}

@end
