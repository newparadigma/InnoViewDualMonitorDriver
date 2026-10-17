#import "Capture.h"

#import <CoreMedia/CoreMedia.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

#include "log.h"

NSString *const MSCaptureErrorDomain = @"MSCapture";

#define MAX_DIRTY 64

@interface MSCapture () <SCStreamOutput, SCStreamDelegate>
@end

@implementation MSCapture {
    MSFrameHandler _handler;
    SCStream *_stream;
    dispatch_queue_t _queue;
}

- (instancetype)initWithDisplay:(CGDirectDisplayID)displayID handler:(MSFrameHandler)handler {
    if ((self = [super init])) {
        _displayID = displayID;
        _handler = [handler copy];
        dispatch_queue_attr_t attr =
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
        _queue = dispatch_queue_create("innoviewdualmonitordriver.capture", attr);
    }
    return self;
}

- (void)startWithCompletion:(void (^)(NSError *_Nullable))completion {
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(_displayID);
    if (!mode) {
        completion([NSError errorWithDomain:MSCaptureErrorDomain code:MSCaptureErrorDisplayNotFound userInfo:nil]);
        return;
    }
    _size = CGSizeMake(CGDisplayModeGetPixelWidth(mode), CGDisplayModeGetPixelHeight(mode));
    CGDisplayModeRelease(mode);

    CGDirectDisplayID target = _displayID;
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                               onScreenWindowsOnly:NO
                                                 completionHandler:^(SCShareableContent *content, NSError *error) {
      dispatch_async(dispatch_get_main_queue(), ^{
        if (error) {
            completion(error);
            return;
        }
        SCDisplay *display = nil;
        for (SCDisplay *d in content.displays)
            if (d.displayID == target) display = d;
        if (!display) {
            completion([NSError errorWithDomain:MSCaptureErrorDomain
                                           code:MSCaptureErrorDisplayNotFound
                                       userInfo:nil]);
            return;
        }
        [self startStreamFor:display completion:completion];
      });
    }];
}

- (void)startStreamFor:(SCDisplay *)display completion:(void (^)(NSError *_Nullable))completion {
    SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
    SCStreamConfiguration *cfg = [[SCStreamConfiguration alloc] init];
    cfg.width = (size_t)_size.width;
    cfg.height = (size_t)_size.height;
    cfg.pixelFormat = kCVPixelFormatType_32BGRA;
    cfg.colorSpaceName = kCGColorSpaceSRGB;
    cfg.minimumFrameInterval = CMTimeMake(1, 60);
    cfg.queueDepth = 4;
    cfg.showsCursor = YES;
    cfg.scalesToFit = NO;
    cfg.capturesAudio = NO;

    NSError *err = nil;
    SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:cfg delegate:self];
    if (![stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:_queue error:&err]) {
        completion(err);
        return;
    }
    _stream = stream;
    [stream startCaptureWithCompletionHandler:^(NSError *error) {
      dispatch_async(dispatch_get_main_queue(), ^{
        if (error) {
            if (self->_stream == stream) self->_stream = nil;
        } else {
            msx_log("capture started: display %u, %.0fx%.0f", self->_displayID, self->_size.width,
                    self->_size.height);
        }
        completion(error);
      });
    }];
}

- (BOOL)running {
    return _stream != nil;
}

- (void)stopWithCompletion:(void (^)(void))completion {
    SCStream *stream = _stream;
    _stream = nil;
    if (!stream) {
        if (completion) completion();
        return;
    }
    [stream stopCaptureWithCompletionHandler:^(NSError *error) {
      if (error) msx_log("capture stop: %s", error.localizedDescription.UTF8String);
      if (completion) dispatch_async(dispatch_get_main_queue(), completion);
    }];
}

#pragma mark - SCStreamOutput / SCStreamDelegate

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sb ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sb)) return;
    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    if (!atts || CFArrayGetCount(atts) == 0) return;
    NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(atts, 0);
    NSNumber *status = info[SCStreamFrameInfoStatus];
    if (!status || status.integerValue != SCFrameStatusComplete) return;
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (!pb) return;

    CGRect rects[MAX_DIRTY];
    size_t n = 0;
    BOOL known = NO;
    NSArray *dirty = info[SCStreamFrameInfoDirtyRects];
    if ([dirty isKindOfClass:[NSArray class]] && dirty.count <= MAX_DIRTY) {
        known = YES;
        for (NSDictionary *d in dirty) {
            CGRect r;
            if (CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)d, &r)) rects[n++] = r;
            else known = NO;
        }
    }
    _handler(pb, known ? rects : NULL, n);
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    msx_log("capture stopped: %s (%ld)", error.localizedDescription.UTF8String, (long)error.code);
    dispatch_async(dispatch_get_main_queue(), ^{
      if (self->_stream != stream) return;
      self->_stream = nil;
      if (self.stoppedWithError) self.stoppedWithError(error);
    });
}

@end
