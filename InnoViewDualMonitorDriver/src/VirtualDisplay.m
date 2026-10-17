#import "VirtualDisplay.h"

#include "log.h"

// Private CoreGraphics classes, declared as protocols and looked up at run
// time so the binary does not link against private symbols.
@protocol MSCGVirtualDisplayDescriptor <NSObject>
@property(retain, nonatomic) dispatch_queue_t queue;
@property(retain, nonatomic) NSString *name;
@property(nonatomic) CGPoint whitePoint;
@property(nonatomic) CGPoint bluePrimary;
@property(nonatomic) CGPoint greenPrimary;
@property(nonatomic) CGPoint redPrimary;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
@property(copy, nonatomic) void (^terminationHandler)(id, id);
@end

@protocol MSCGVirtualDisplayMode <NSObject>
- (id)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
@end

@protocol MSCGVirtualDisplaySettings <NSObject>
@property(retain, nonatomic) NSArray *modes;
@property(nonatomic) unsigned int hiDPI;
@end

@protocol MSCGVirtualDisplay <NSObject>
@property(readonly, nonatomic) unsigned int displayID;
- (id)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
@end

// Same identity as the vendor driver's display (EDID of the InnoView panel),
// so macOS treats it as the same monitor.
static const unsigned int kVendorID = 0x6474;
static const unsigned int kProductID = 0x95AF;
static const CGSize kPanelMM = {344, 194};  // 15.6" 16:9

@implementation MSVirtualDisplay {
    id<MSCGVirtualDisplay> _display;
}

- (nullable instancetype)initWithName:(NSString *)name modes:(NSArray<NSValue *> *)sizes serial:(uint32_t)serial {
    if (!(self = [super init])) return nil;
    Class descCls = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class modeCls = NSClassFromString(@"CGVirtualDisplayMode");
    Class setCls = NSClassFromString(@"CGVirtualDisplaySettings");
    Class dispCls = NSClassFromString(@"CGVirtualDisplay");
    if (!descCls || !modeCls || !setCls || !dispCls || sizes.count == 0) {
        msx_log("CGVirtualDisplay API is not available");
        return nil;
    }

    unsigned int maxW = 0, maxH = 0;
    NSMutableArray *modes = [NSMutableArray array];
    for (NSValue *v in sizes) {
        CGSize s = v.sizeValue;
        maxW = MAX(maxW, (unsigned int)s.width);
        maxH = MAX(maxH, (unsigned int)s.height);
        [modes addObject:[(id<MSCGVirtualDisplayMode>)[modeCls alloc] initWithWidth:(unsigned int)s.width
                                                                            height:(unsigned int)s.height
                                                                       refreshRate:60]];
    }

    id<MSCGVirtualDisplayDescriptor> desc = [[descCls alloc] init];
    desc.queue = dispatch_get_main_queue();
    desc.name = name;
    desc.maxPixelsWide = maxW;
    desc.maxPixelsHigh = maxH;
    desc.sizeInMillimeters = kPanelMM;
    desc.vendorID = kVendorID;
    desc.productID = kProductID;
    desc.serialNum = serial;
    // sRGB primaries: captured BGRA can be sent as is.
    desc.redPrimary = CGPointMake(0.640, 0.330);
    desc.greenPrimary = CGPointMake(0.300, 0.600);
    desc.bluePrimary = CGPointMake(0.150, 0.060);
    desc.whitePoint = CGPointMake(0.3127, 0.3290);
    __weak MSVirtualDisplay *weakSelf = self;
    desc.terminationHandler = ^(id a, id b) {
      msx_log("virtual display terminated by the system");
      dispatch_async(dispatch_get_main_queue(), ^{
        MSVirtualDisplay *s = weakSelf;
        if (s.terminated) s.terminated();
      });
    };

    _display = [(id<MSCGVirtualDisplay>)[dispCls alloc] initWithDescriptor:desc];
    if (!_display || _display.displayID == 0) {
        msx_log("CGVirtualDisplay creation failed");
        return nil;
    }
    id<MSCGVirtualDisplaySettings> settings = [[setCls alloc] init];
    settings.hiDPI = 0;
    settings.modes = modes;
    if (![_display applySettings:settings]) {
        msx_log("CGVirtualDisplay applySettings failed");
        return nil;
    }
    msx_log("virtual display %u created (%ux%u max, %lu modes)", _display.displayID, maxW, maxH,
            (unsigned long)modes.count);
    return self;
}

- (CGDirectDisplayID)displayID {
    return _display.displayID;
}

- (void)dealloc {
    msx_log("virtual display %u removed", _display.displayID);
}

@end
