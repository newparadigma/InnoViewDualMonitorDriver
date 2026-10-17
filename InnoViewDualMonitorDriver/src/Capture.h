// ScreenCaptureKit stream of one display: BGRA frames + dirty rectangles.
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Called on the capture queue. dirty == NULL means "treat the whole frame as changed";
// otherwise count may be 0 (nothing changed, e.g. a repeated frame).
typedef void (^MSFrameHandler)(CVPixelBufferRef frame, const CGRect *_Nullable dirty, size_t count);

@interface MSCapture : NSObject

- (instancetype)initWithDisplay:(CGDirectDisplayID)displayID handler:(MSFrameHandler)handler;

// Completion and stop handlers run on the main queue.
- (void)startWithCompletion:(void (^)(NSError *_Nullable error))completion;
- (void)stopWithCompletion:(nullable void (^)(void))completion;

@property(nonatomic, copy, nullable) void (^stoppedWithError)(NSError *error);
@property(nonatomic, readonly) CGDirectDisplayID displayID;
@property(nonatomic, readonly) CGSize size;  // pixels being captured

@end

// Errors from -startWithCompletion: in addition to SCStreamErrorDomain ones.
extern NSString *const MSCaptureErrorDomain;
enum { MSCaptureErrorDisplayNotFound = 1 };

NS_ASSUME_NONNULL_END
