// Ties the USB device, the virtual display and screen capture together.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MSState) {
    MSStateStarting,
    MSStateNoDevice,
    MSStateBusy,        // device opened by another program (vendor driver?)
    MSStateError,       // open/init failed, retrying
    MSStateWaitSink,    // device ok, monitor not reporting HPD
    MSStateWaitFrame,   // waiting for the first captured frame
    MSStateStreaming,
    MSStateBlanked,     // displays asleep
    MSStateSleeping,    // system sleep
};

@interface MSController : NSObject

// Called on the main queue whenever state/detail changes.
@property(nonatomic, copy, nullable) void (^changed)(void);

- (void)start;
// Blocks (up to ~2 s) until the device has been switched off and released.
- (void)shutdown;

- (void)systemWillSleep;
- (void)systemDidWake;
- (void)displaysDidSleep;
- (void)displaysDidWake;

// Snapshot for the UI (main thread).
@property(nonatomic, readonly) MSState state;
@property(nonatomic, readonly, copy) NSString *detail;
@property(nonatomic, readonly) int usbSpeed;
@property(nonatomic, readonly) BOOL captureDenied;
@property(nonatomic, readonly) BOOL needsRelaunch;  // permission granted, capture needs a restart
@property(nonatomic, readonly) CGDirectDisplayID displayID;  // 0 if none
@property(nonatomic, readonly) CGSize streamSize;
- (void)takeStatsFps:(double *)fps mbps:(double *)mbps;

// The panel reports it is upside down; the driver flips the picture.
@property(nonatomic, readonly) BOOL rotated;

// Pixel conversion on the GPU (Metal) or the CPU; persisted. Switchable at any time.
@property(nonatomic, readonly) BOOL gpuAvailable;
@property(nonatomic) BOOL convertOnGPU;

// Modes offered by the virtual display; switching goes through macOS.
- (NSArray<NSValue *> *)supportedSizes;
- (CGSize)currentSize;
- (void)selectSize:(CGSize)size;

@end

NS_ASSUME_NONNULL_END
