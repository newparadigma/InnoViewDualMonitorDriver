// Virtual display backed by the private CGVirtualDisplay API (macOS 11+).
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MSVirtualDisplay : NSObject

// sizes: NSValue(CGSize) pixel modes, first one is the default. Returns nil on failure.
- (nullable instancetype)initWithName:(NSString *)name
                                modes:(NSArray<NSValue *> *)sizes
                               serial:(uint32_t)serial;

@property(nonatomic, readonly) CGDirectDisplayID displayID;

@end

NS_ASSUME_NONNULL_END
