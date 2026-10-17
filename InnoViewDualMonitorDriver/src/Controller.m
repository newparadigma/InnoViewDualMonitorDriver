#import "Controller.h"

#import <CoreVideo/CoreVideo.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include <errno.h>
#include <os/lock.h>
#include <pthread.h>
#include <stdatomic.h>
#include <time.h>

#import "Capture.h"
#import "GPUConverter.h"
#import "VirtualDisplay.h"
#include "frame.h"
#include "log.h"
#include "ms9132.h"

#define DISPLAY_GRACE_S 5.0  // keep the virtual display this long after unplug or HPD loss
#define HPD_CHECK_S 0.5  // status register poll, as the vendor driver
#define HPD_MISSES 2     // consecutive HPD-low reads before the monitor counts as gone
// The screen goes dark a few seconds after the last transfer, so while the
// picture is static a tiny unchanged area is resent (the vendor driver keeps
// sending ~2 frames/s for the same reason).
#define KEEPALIVE_S 0.5
#define SEND_TIMEOUT_MS 3000
#define MAX_W 1920
#define MAX_H 1080

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static const char *state_name(MSState s) {
    switch (s) {
    case MSStateStarting: return "starting";
    case MSStateNoDevice: return "no device";
    case MSStateBusy: return "busy";
    case MSStateError: return "error";
    case MSStateWaitSink: return "waiting for monitor";
    case MSStateWaitFrame: return "waiting for first frame";
    case MSStateStreaming: return "streaming";
    case MSStateBlanked: return "blanked";
    case MSStateSleeping: return "sleeping";
    }
    return "?";
}

static void display_reconfigured(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *ctx);

@implementation MSController {
    // Shared between the capture queue, the device thread and main, guarded by _fl.
    pthread_mutex_t _fl;
    pthread_cond_t _fc;
    uint8_t *_shadow;  // current screen content in chip format
    id<MTLBuffer> _shadowBuf;  // backs _shadow when Metal is available
    MSGPUConverter *_gpu;
    BOOL _useGPU, _gpuFailureLogged;
    int _sw, _sh, _bpp;
    uint8_t _fmt;      // format of _shadow
    uint8_t _wantFmt;  // format chosen at startup
    uint64_t _gen;     // bumped whenever _shadow is reallocated or invalidated
    uint64_t _captureEpoch;  // frames of captures started before the last bump are dropped
    BOOL _frameValid;
    BOOL _resync;      // both chip buffers need the whole frame again
    BOOL _rotate180;   // panel is upside down (from the status register)
    ms_rect _pending;  // changed since the last transfer (chip coordinates)
    BOOL _quit, _sleepReq, _blankReq;
    BOOL _screenOffReq;  // the virtual display is gone: switch the panel off
    BOOL _displayWanted;

    // Device thread only.
    ms_dev *_dev;
    uint8_t *_pkt;
    size_t _pktCap;
    uint64_t _cfgGen;    // generation the chip is configured for, 0 = not configured
    ms_rect _prevDirty;  // new content of the previous transfer (the chip double-buffers)
    BOOL _screenEnabled, _sinkPresent, _edidRead;
    int _hpdMisses;
    double _lastHpdCheck;
    double _lastSend;
    int _lastOpenError;
    uint32_t _edidSerial;

    _Atomic uint64_t _statFrames, _statBytes;
    // For the periodic log line: captured frames with changes, full-frame
    // transfers, time spent inside bulk transfers.
    _Atomic uint64_t _statCaptured, _statFull, _statSendNs;
    uint64_t _logPrev[5];
    double _logPrevTime;
    dispatch_source_t _statsTimer;
    uint64_t _lastFrames, _lastBytes;
    double _lastStatTime;

    dispatch_semaphore_t _threadDone, _sleepDone;
    NSThread *_thread;

    // Main thread only.
    MSVirtualDisplay *_vd;
    MSCapture *_capture;
    BOOL _captureStarting, _accessRequested, _retryScheduled, _needsRelaunch;
    BOOL _displaysAsleep, _displayFailed;
    double _wakeTime;
    NSString *_lastCaptureError;
    int _notFoundRetries;

    // UI snapshot.
    os_unfair_lock _sl;
    MSState _state;
    NSString *_detail;
    int _usbSpeed;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    pthread_mutex_init(&_fl, NULL);
    pthread_cond_init(&_fc, NULL);
    _sl = OS_UNFAIR_LOCK_INIT;
    _state = MSStateStarting;
    _detail = @"";
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults registerDefaults:@{@"ConvertOnGPU" : @YES}];
    _wantFmt = [defaults boolForKey:@"ExperimentalRGB"] ? MS_PIXFMT_RGB888 : MS_PIXFMT_UYVY;
    _gpu = [[MSGPUConverter alloc] init];
    _useGPU = [defaults boolForKey:@"ConvertOnGPU"] && self.gpuAvailable;
    msx_log("pixel conversion on the %s", _useGPU ? "GPU" : "CPU");
    _pktCap = ms_packet_size(MAX_W, MAX_H, 3);
    _pkt = valloc(_pktCap);
    _threadDone = dispatch_semaphore_create(0);
    _sleepDone = dispatch_semaphore_create(0);
    ms_global_init(msx_log_line);
    CGDisplayRegisterReconfigurationCallback(display_reconfigured, (__bridge void *)self);
    if (_wantFmt == MS_PIXFMT_RGB888) msx_log("experimental RGB888 mode enabled");
    return self;
}

- (void)start {
    _thread = [[NSThread alloc] initWithTarget:self selector:@selector(deviceThread) object:nil];
    _thread.name = @"innoviewdualmonitordriver.device";
    _thread.qualityOfService = NSQualityOfServiceUserInteractive;
    [_thread start];

    _logPrevTime = now_s();
    _statsTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_statsTimer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC,
                              NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(_statsTimer, ^{
      [self logStats];
    });
    dispatch_resume(_statsTimer);
}

// One log line per 5 s while frames are being sent.
- (void)logStats {
    uint64_t cur[5] = {atomic_load(&_statFrames), atomic_load(&_statBytes), atomic_load(&_statCaptured),
                       atomic_load(&_statFull), atomic_load(&_statSendNs)};
    double t = now_s(), dt = t - _logPrevTime;
    uint64_t frames = cur[0] - _logPrev[0], bytes = cur[1] - _logPrev[1], captured = cur[2] - _logPrev[2],
             full = cur[3] - _logPrev[3], sendNs = cur[4] - _logPrev[4];
    memcpy(_logPrev, cur, sizeof cur);
    _logPrevTime = t;
    if (frames == 0 || dt <= 0) return;
    msx_log("stats: captured %.1f fps, sent %.1f fps (%.0f%% full), %.1f MB/s, USB busy %.0f%%, %.1f ms/transfer, %s",
            captured / dt, frames / dt, 100.0 * full / frames, bytes / dt / 1e6, sendNs / 1e9 / dt * 100,
            sendNs / 1e6 / frames, self.convertOnGPU ? "GPU" : "CPU");
}

- (void)shutdown {
    pthread_mutex_lock(&_fl);
    _quit = YES;
    pthread_cond_broadcast(&_fc);
    pthread_mutex_unlock(&_fl);
    if (_thread && dispatch_semaphore_wait(_threadDone, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)))
        msx_log("device thread did not stop in time");
    CGDisplayRemoveReconfigurationCallback(display_reconfigured, (__bridge void *)self);
    [_capture stopWithCompletion:nil];
    _capture = nil;
    _vd = nil;
}

#pragma mark - Power events (main thread)

- (void)setFlag:(BOOL *)flag to:(BOOL)value {
    pthread_mutex_lock(&_fl);
    *flag = value;
    pthread_cond_broadcast(&_fc);
    pthread_mutex_unlock(&_fl);
}

- (void)systemWillSleep {
    msx_log("system will sleep");
    // Also when the displays did not report sleeping first.
    pthread_mutex_lock(&_fl);
    [self discardFrames];
    pthread_mutex_unlock(&_fl);
    while (dispatch_semaphore_wait(_sleepDone, DISPATCH_TIME_NOW) == 0) {
    }
    [self setFlag:&_sleepReq to:YES];
    dispatch_semaphore_wait(_sleepDone, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
}

- (void)systemDidWake {
    msx_log("system did wake");
    [self setFlag:&_sleepReq to:NO];
    // Frames are dropped since "will sleep". With the displays asleep the
    // capture restarts on their wake; otherwise nothing else restarts it.
    if (!_displaysAsleep) {
        _wakeTime = now_s();
        [self restartCapture];
    }
}

- (void)displaysDidSleep {
    msx_log("displays did sleep");
    _displaysAsleep = YES;  // no capture restarts until wake
    pthread_mutex_lock(&_fl);
    _blankReq = YES;
    [self discardFrames];
    pthread_cond_broadcast(&_fc);
    pthread_mutex_unlock(&_fl);
}

// Called with _fl held. The current picture is never shown again (after
// sleep the lock screen may be up), and frames still arriving from the
// running capture are dropped: only a capture started afterwards counts.
- (void)discardFrames {
    _captureEpoch++;
    _frameValid = NO;
}

// NSWorkspace reports display wake up to ~0.65 s after WindowServer powers the
// displays on, so the USB screen lights up a bit after the DisplayPort one.
// Earlier signals were tried on 12.10.2026 (CGDisplayIsAsleep, framebuffer and
// root domain power messages, IOPMUserIsActive) and did not help reliably.
- (void)displaysDidWake {
    msx_log("displays did wake");
    _displaysAsleep = NO;
    _wakeTime = now_s();
    [self setFlag:&_blankReq to:NO];
    [self restartCapture];
}

#pragma mark - UI snapshot

- (void)notify {
    if (self.changed) self.changed();
}

- (void)setState:(MSState)state detail:(NSString *)detail {
    os_unfair_lock_lock(&_sl);
    BOOL changed = _state != state || ![_detail isEqualToString:detail];
    MSState old = _state;
    _state = state;
    _detail = [detail copy];
    os_unfair_lock_unlock(&_sl);
    if (!changed) return;
    if (old != state) msx_log("state: %s -> %s %s", state_name(old), state_name(state), detail.UTF8String);
    dispatch_async(dispatch_get_main_queue(), ^{
      [self notify];
    });
}

- (MSState)state {
    os_unfair_lock_lock(&_sl);
    MSState s = _state;
    os_unfair_lock_unlock(&_sl);
    return s;
}

- (NSString *)detail {
    os_unfair_lock_lock(&_sl);
    NSString *d = _detail;
    os_unfair_lock_unlock(&_sl);
    return d;
}

- (int)usbSpeed {
    os_unfair_lock_lock(&_sl);
    int s = _usbSpeed;
    os_unfair_lock_unlock(&_sl);
    return s;
}

- (void)setUsbSpeed:(int)speed {
    os_unfair_lock_lock(&_sl);
    _usbSpeed = speed;
    os_unfair_lock_unlock(&_sl);
}

- (void)takeStatsFps:(double *)fps mbps:(double *)mbps {
    double t = now_s();
    uint64_t f = atomic_load(&_statFrames), b = atomic_load(&_statBytes);
    double dt = t - _lastStatTime;
    *fps = *mbps = 0;
    if (_lastStatTime > 0 && dt > 0) {
        *fps = (f - _lastFrames) / dt;
        *mbps = (b - _lastBytes) / dt / 1e6;
    }
    _lastStatTime = t;
    _lastFrames = f;
    _lastBytes = b;
}

#pragma mark - Device thread

// Sleeps up to `seconds`, returning early if quit/sleep/blank flags change.
- (void)waitFor:(double)seconds {
    double deadline = now_s() + seconds;
    pthread_mutex_lock(&_fl);
    BOOL q = _quit, s = _sleepReq, b = _blankReq;
    for (;;) {
        double left = deadline - now_s();
        if (left <= 0 || _quit != q || _sleepReq != s || _blankReq != b) break;
        struct timespec ts = {(time_t)left, (long)((left - (time_t)left) * 1e9)};
        pthread_cond_timedwait_relative_np(&_fc, &_fl, &ts);
    }
    pthread_mutex_unlock(&_fl);
}

- (void)deviceThread {
    double lastPresent = now_s();
    for (;;) {
        pthread_mutex_lock(&_fl);
        BOOL quit = _quit, sleep = _sleepReq;
        pthread_mutex_unlock(&_fl);
        if (quit) break;
        if (sleep) {
            [self enterSleep];
            continue;
        }

        if (!_dev) {
            int r = ms_open(&_dev);
            if (r == MS_ERR_NOT_FOUND) {
                if (_lastOpenError != r) msx_log("device not found");
                _lastOpenError = r;
                [self setUsbSpeed:0];
                [self setState:MSStateNoDevice detail:@""];
                if (now_s() - lastPresent > DISPLAY_GRACE_S) [self setDisplayWanted:NO];
                [self waitFor:1.0];
                continue;
            }
            lastPresent = now_s();
            if (r < 0) {
                if (_lastOpenError != r) msx_log("open failed: %s (0x%08x)", ms_strerror(r), r);
                _lastOpenError = r;
                if (r == MS_ERR_BUSY)
                    [self setState:MSStateBusy detail:@"used by another app (vendor driver?)"];
                else
                    [self setState:MSStateError detail:[NSString stringWithUTF8String:ms_strerror(r)]];
                [self waitFor:r == MS_ERR_BUSY ? 2.0 : 1.0];
                continue;
            }
            _lastOpenError = 0;
            if ([self initDevice] < 0) {
                [self releaseDevice:NO];
                [self waitFor:1.0];
                continue;
            }
        }

        if (!_sinkPresent) {
            uint8_t raw = 0;
            int r = ms_hpd(_dev, &raw);
            if (r < 0) {
                [self deviceFailed:r what:"HPD read"];
                continue;
            }
            if (r == 0) {
                [self setState:MSStateWaitSink detail:@""];
                // As the vendor driver: no monitor, no display (windows would be stranded on it).
                if (now_s() - lastPresent > DISPLAY_GRACE_S) [self setDisplayWanted:NO];
                [self waitFor:0.5];
                continue;
            }
            msx_log("monitor connected (status 0x%02x)", raw);
            _sinkPresent = YES;
            _hpdMisses = 0;
            _lastHpdCheck = now_s();
            [self applyStatus:raw];
            [self readEdid];
            [self setDisplayWanted:YES];
        }
        lastPresent = now_s();

        int r = [self streamStep];
        if (r < 0) [self deviceFailed:r what:"stream"];
    }
    [self releaseDevice:YES];
    dispatch_semaphore_signal(_threadDone);
}

- (int)initDevice {
    const ms_info *info = ms_get_info(_dev);
    int r;
    if ((r = ms_power_on(_dev, 1)) < 0 || (r = ms_video_on(_dev, 0)) < 0 || (r = ms_screen_on(_dev, 0)) < 0) {
        msx_log("device init failed: %s (0x%08x)", ms_strerror(r), r);
        [self setState:MSStateError detail:[NSString stringWithUTF8String:ms_strerror(r)]];
        return r;
    }
    _cfgGen = 0;
    _screenEnabled = NO;
    _sinkPresent = NO;
    if (info->usb_speed == 2) msx_log("warning: device runs at USB 2.0, frame rate will be limited");
    [self setUsbSpeed:info->usb_speed];
    [self setState:MSStateWaitSink detail:@""];
    return 0;
}

- (void)releaseDevice:(BOOL)polite {
    if (!_dev) return;
    if (polite) {
        ms_stop_stream(_dev);
        ms_power_on(_dev, 0);
    }
    ms_close(_dev);
    _dev = NULL;
    _sinkPresent = NO;
    _screenEnabled = NO;
    _cfgGen = 0;
    msx_log("device released");
}

- (void)deviceFailed:(int)r what:(const char *)what {
    msx_log("%s failed: %s (0x%08x), reopening", what, ms_strerror(r), r);
    [self releaseDevice:NO];
    [self setState:MSStateError detail:[NSString stringWithUTF8String:ms_strerror(r)]];
    [self waitFor:0.5];
}

- (void)enterSleep {
    [self releaseDevice:YES];
    [self setState:MSStateSleeping detail:@""];
    dispatch_semaphore_signal(_sleepDone);
    pthread_mutex_lock(&_fl);
    while (_sleepReq && !_quit) pthread_cond_wait(&_fc, &_fl);
    pthread_mutex_unlock(&_fl);
}

- (void)readEdid {
    if (_edidRead) return;
    uint8_t edid[256];
    int n = ms_read_edid(_dev, edid);
    if (n < 0) {
        msx_log("EDID read failed: %s", ms_strerror(n));
        return;
    }
    msx_log_hex("EDID:", edid, (size_t)n);
    _edidSerial = edid[12] | edid[13] << 8 | edid[14] << 16 | (uint32_t)edid[15] << 24;
    _edidRead = YES;
}

// Follows the orientation sensor: the picture is kept upright by flipping it in the driver.
- (void)applyStatus:(uint8_t)raw {
    BOOL rotate = (raw & MS_STATUS_ROTATED) != 0;
    pthread_mutex_lock(&_fl);
    BOOL changed = rotate != _rotate180;
    if (changed) {
        _rotate180 = rotate;
        if (_frameValid) {
            // Flip what we already have; new captures are converted in the new orientation.
            ms_rotate180_inplace(_shadow, _sw, _sh, _fmt);
            _pending = ms_rect_full(_sw, _sh);
            _resync = YES;
            pthread_cond_broadcast(&_fc);
        }
    }
    pthread_mutex_unlock(&_fl);
    if (changed) {
        msx_log("orientation: %s (status 0x%02x)", rotate ? "upside down, flipping picture" : "normal", raw);
        dispatch_async(dispatch_get_main_queue(), ^{
          [self notify];
        });
    }
}

// Displays asleep: blank the picture. The panel keeps its backlight on: it
// stays lit (black) even without an HDMI signal, so power_on(0) does not help
// and only makes the monitor re-enumerate USB and wake slower (tested
// 12.10.2026). The device is checked every few seconds so that a reset during
// sleep is handled before wake.
- (int)blankStep {
    if (_screenEnabled) {
        ms_stop_stream(_dev);
        _screenEnabled = NO;
        _cfgGen = 0;  // full reconfigure on wake
        msx_log("displays asleep: screen off");
    }
    [self setState:MSStateBlanked detail:@""];
    [self waitFor:2.0];
    pthread_mutex_lock(&_fl);
    BOOL stillBlank = _blankReq;
    pthread_mutex_unlock(&_fl);
    return stillBlank ? MIN(ms_hpd(_dev, NULL), 0) : 0;
}

// Waits for new content and sends one transfer. <0 = device error.
- (int)streamStep {
    pthread_mutex_lock(&_fl);
    BOOL blank = _blankReq;
    pthread_mutex_unlock(&_fl);
    if (blank) return [self blankStep];

    double t = now_s();
    if (t - _lastHpdCheck >= HPD_CHECK_S) {
        _lastHpdCheck = t;
        uint8_t raw = 0;
        int h = ms_hpd(_dev, &raw);
        if (h < 0) return h;
        if (h == 0) {
            if (++_hpdMisses >= HPD_MISSES) {
                msx_log("monitor disconnected (status 0x%02x)", raw);
                _sinkPresent = NO;
                _screenEnabled = NO;
                _cfgGen = 0;
                return 0;
            }
        } else {
            _hpdMisses = 0;
            [self applyStatus:raw];
        }
    }

    pthread_mutex_lock(&_fl);
    double deadline = _screenEnabled ? MIN(t + 1.0, _lastSend + KEEPALIVE_S) : t + 1.0;
    while (!_quit && !_sleepReq && !_blankReq && !_screenOffReq &&
           !(_frameValid && (_gen != _cfgGen || !ms_rect_empty(_pending)))) {
        double left = deadline - now_s();
        if (left <= 0) break;
        struct timespec ts = {(time_t)left, (long)((left - (time_t)left) * 1e9)};
        pthread_cond_timedwait_relative_np(&_fc, &_fl, &ts);
    }
    // Moot if a new display already delivered a frame.
    BOOL off = _screenOffReq && !_frameValid;
    _screenOffReq = NO;
    BOOL keepalive = NO;
    if (_quit || _sleepReq || _blankReq || !_frameValid || (_gen == _cfgGen && ms_rect_empty(_pending))) {
        keepalive = !_quit && !_sleepReq && !_blankReq && _frameValid && _gen == _cfgGen && _screenEnabled &&
                    now_s() >= _lastSend + KEEPALIVE_S;
        if (!keepalive) {
            BOOL noFrame = !_frameValid;
            pthread_mutex_unlock(&_fl);
            if (off && _screenEnabled) {
                ms_stop_stream(_dev);
                _screenEnabled = NO;
                _cfgGen = 0;  // full reconfigure when the display is back
                msx_log("virtual display removed: screen off");
            }
            if (noFrame && !_screenEnabled) [self setState:MSStateWaitFrame detail:@""];
            return 0;
        }
    }

    if (_gen != _cfgGen) {
        uint64_t gen = _gen;
        int w = _sw, h = _sh;
        uint8_t fmt = _fmt;
        pthread_mutex_unlock(&_fl);
        const ms_mode *mode = ms_find_mode(w, h, 0);
        if (!mode) {
            [self setState:MSStateError detail:[NSString stringWithFormat:@"mode %d×%d is not supported", w, h]];
            [self waitFor:1.0];
            return 0;
        }
        if (_screenEnabled) {
            ms_stop_stream(_dev);
            _screenEnabled = NO;
        }
        int r = ms_configure_stream(_dev, mode, fmt);
        if (r < 0) return r;
        pthread_mutex_lock(&_fl);
        if (_gen != gen) {  // resized again meanwhile
            pthread_mutex_unlock(&_fl);
            return 0;
        }
        _cfgGen = gen;
        _pending = ms_rect_full(w, h);
        _resync = YES;
    }
    if (_resync) {
        // Both chip buffers are stale: the next two transfers are full frames.
        _prevDirty = ms_rect_full(_sw, _sh);
        _resync = NO;
    }

    ms_rect dirty = _pending;
    ms_rect send = ms_rect_union(dirty, _prevDirty);
    // Keepalive: current content, so it is safe for either chip buffer.
    if (keepalive) send = ms_rect_union(send, (ms_rect){0, 0, MS_RECT_ALIGN, 16});
    _pending = (ms_rect){0, 0, 0, 0};
    int w = _sw, h = _sh;
    size_t len = ms_build_packet(_pkt, _shadow, (size_t)_sw * _bpp, _bpp, send);
    pthread_mutex_unlock(&_fl);

    double sendStart = now_s();
    int r = ms_send(_dev, _pkt, (int)len, SEND_TIMEOUT_MS);
    if (r < 0) return r;
    _lastSend = now_s();
    _prevDirty = dirty;
    if (keepalive) return 0;  // not counted in the statistics
    atomic_fetch_add(&_statFrames, 1);
    atomic_fetch_add(&_statBytes, len);
    atomic_fetch_add(&_statSendNs, (uint64_t)((now_s() - sendStart) * 1e9));
    if (send.w == w && send.h == h) atomic_fetch_add(&_statFull, 1);

    if (!_screenEnabled) {
        // Vendor order: first full frame, then screen on + video on.
        if ((r = ms_screen_on(_dev, 1)) < 0 || (r = ms_video_on(_dev, 1)) < 0) return r;
        _screenEnabled = YES;
        msx_log("streaming %dx%d", w, h);
    }
    [self setState:MSStateStreaming detail:[NSString stringWithFormat:@"%d×%d", w, h]];
    return 0;
}

#pragma mark - Frames (capture queue)

// Called with _fl held. With Metal the frame lives in shared CPU/GPU memory,
// so either converter can write it and switching needs no reallocation.
- (BOOL)allocShadowWidth:(int)w height:(int)h {
    int bpp = ms_bytes_per_pixel(_wantFmt);
    size_t len = (size_t)w * h * bpp;
    if (_gpu) {
        id<MTLBuffer> buf = [_gpu newFrameBufferWithLength:len];
        if (!buf) return NO;
        _shadowBuf = buf;
        _shadow = buf.contents;
    } else {
        uint8_t *buf = realloc(_shadow, len);
        if (!buf) return NO;
        _shadow = buf;
    }
    _sw = w;
    _sh = h;
    _bpp = bpp;
    _fmt = _wantFmt;
    _gen++;
    _frameValid = NO;
    _pending = (ms_rect){0, 0, 0, 0};
    msx_log("frame buffer %dx%d", w, h);
    return YES;
}

// Called with _fl held.
- (BOOL)convertOnCPU:(CVPixelBufferRef)pb rects:(const ms_rect *)rects count:(size_t)count rotate:(BOOL)rotate {
    if (CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return NO;
    const uint8_t *base = CVPixelBufferGetBaseAddress(pb);
    size_t stride = CVPixelBufferGetBytesPerRow(pb), dstride = (size_t)_sw * _bpp;
    for (size_t i = 0; i < count; i++) {
        if (rotate)
            ms_convert_rect_rot180(base, stride, _sw, _sh, _shadow, dstride, rects[i], _fmt);
        else
            ms_convert_rect(base, stride, _shadow, dstride, rects[i], _fmt);
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    return YES;
}

- (void)ingestFrame:(CVPixelBufferRef)pb dirty:(const CGRect *)dirty count:(size_t)n epoch:(uint64_t)epoch {
    if (CVPixelBufferGetPixelFormatType(pb) != kCVPixelFormatType_32BGRA) return;
    int w = (int)CVPixelBufferGetWidth(pb), h = (int)CVPixelBufferGetHeight(pb);

    pthread_mutex_lock(&_fl);
    if (epoch != _captureEpoch) {  // a late frame of a capture that no longer counts
        pthread_mutex_unlock(&_fl);
        return;
    }
    if ((!_shadow || w != _sw || h != _sh || _fmt != _wantFmt) && ![self allocShadowWidth:w height:h]) {
        pthread_mutex_unlock(&_fl);
        return;
    }
    BOOL rotate = _rotate180;
    ms_rect rects[64];
    size_t count = 0;
    if (!_frameValid || !dirty) {
        rects[count++] = ms_rect_full(w, h);
    } else {
        for (size_t i = 0; i < n && count < 64; i++) {
            CGRect c = CGRectIntegral(dirty[i]);
            ms_rect r = ms_rect_align(
                (ms_rect){(int)c.origin.x, (int)c.origin.y, (int)c.size.width, (int)c.size.height}, w, h);
            if (!ms_rect_empty(r)) rects[count++] = r;
        }
    }

    BOOL gpu = _useGPU && _shadowBuf && _fmt == MS_PIXFMT_UYVY;
    BOOL ok = gpu && [_gpu convert:pb rects:rects count:count rotate:rotate to:_shadowBuf width:w height:h];
    if (gpu && !ok && !_gpuFailureLogged) {
        msx_log("GPU conversion failed, converting on the CPU");
        _gpuFailureLogged = YES;
    }
    if (!ok) ok = [self convertOnCPU:pb rects:rects count:count rotate:rotate];
    if (!ok) {
        pthread_mutex_unlock(&_fl);
        return;
    }

    if (!_frameValid) _resync = YES;
    _frameValid = YES;
    ms_rect changed = {0, 0, 0, 0};
    for (size_t i = 0; i < count; i++) changed = ms_rect_union(changed, rotate ? ms_rect_rot180(rects[i], w, h) : rects[i]);
    if (!ms_rect_empty(changed)) {
        _pending = ms_rect_union(_pending, changed);
        atomic_fetch_add(&_statCaptured, 1);
        pthread_cond_broadcast(&_fc);
    }
    pthread_mutex_unlock(&_fl);
}

- (BOOL)gpuAvailable {
    return _gpu != nil && _wantFmt == MS_PIXFMT_UYVY;
}

- (BOOL)convertOnGPU {
    pthread_mutex_lock(&_fl);
    BOOL on = _useGPU;
    pthread_mutex_unlock(&_fl);
    return on;
}

- (void)setConvertOnGPU:(BOOL)on {
    pthread_mutex_lock(&_fl);
    _useGPU = on && self.gpuAvailable;
    _gpuFailureLogged = NO;
    pthread_mutex_unlock(&_fl);
    [NSUserDefaults.standardUserDefaults setBool:on forKey:@"ConvertOnGPU"];
    msx_log("pixel conversion on the %s", on && self.gpuAvailable ? "GPU" : "CPU");
}

#pragma mark - Virtual display and capture (main thread)

// Device thread: request creation/removal of the virtual display.
- (void)setDisplayWanted:(BOOL)wanted {
    pthread_mutex_lock(&_fl);
    BOOL changed = _displayWanted != wanted;
    _displayWanted = wanted;
    pthread_mutex_unlock(&_fl);
    if (changed)
        dispatch_async(dispatch_get_main_queue(), ^{
          [self syncDisplay];
        });
}

- (void)syncDisplay {
    pthread_mutex_lock(&_fl);
    BOOL wanted = _displayWanted && !_quit;
    pthread_mutex_unlock(&_fl);

    if (wanted && !_vd) {
        // Without Screen Recording the display would stay dark, and macOS may open
        // the permission prompt or System Settings right on it: create it only once
        // the permission is there (and works without a relaunch).
        if (_needsRelaunch) return;
        if (!CGPreflightScreenCaptureAccess()) {
            [self waitForPermission];
            return;
        }
        MSVirtualDisplay *vd = [[MSVirtualDisplay alloc] initWithName:@"InnoView USB"
                                                                modes:[self supportedSizes]
                                                               serial:_edidSerial ? _edidSerial : 1];
        if (!vd) {
            // Shown in the menu: a state set from here would be overwritten by the device thread.
            _displayFailed = YES;
            [self notify];
            [self scheduleCaptureRetry:5.0];
            return;
        }
        _displayFailed = NO;
        __weak MSController *weakSelf = self;
        __weak MSVirtualDisplay *weakVd = vd;
        vd.terminated = ^{
          [weakSelf displayTerminated:weakVd];
        };
        _vd = vd;
        _displayID = vd.displayID;
        [self startCapture];
    } else if (!wanted) {
        _displayFailed = NO;
        if (_vd) [self removeDisplay];
    }
    [self notify];
}

// The system removed the virtual display by itself: forget it and create a new one.
- (void)displayTerminated:(MSVirtualDisplay *)vd {
    if (!vd || vd != _vd) return;
    [self removeDisplay];
    [self notify];
    [self scheduleCaptureRetry:1.0];
}

- (void)removeDisplay {
    [_capture stopWithCompletion:nil];
    _capture = nil;
    _vd = nil;
    _displayID = 0;
    pthread_mutex_lock(&_fl);
    [self discardFrames];
    _screenOffReq = YES;
    pthread_cond_broadcast(&_fc);
    pthread_mutex_unlock(&_fl);
}

- (BOOL)displayFailed {
    return _displayFailed;
}

- (BOOL)rotated {
    pthread_mutex_lock(&_fl);
    BOOL r = _rotate180;
    pthread_mutex_unlock(&_fl);
    return r;
}

- (void)startCapture {
    if (!_vd || _capture || _captureStarting || _needsRelaunch || _displaysAsleep) return;
    if (!CGPreflightScreenCaptureAccess()) {
        [self waitForPermission];
        return;
    }
    _captureStarting = YES;
    uint64_t epoch = [self captureEpoch];
    __weak MSController *weakSelf = self;
    MSCapture *cap = [[MSCapture alloc] initWithDisplay:_vd.displayID
                                                handler:^(CVPixelBufferRef pb, const CGRect *dirty, size_t n) {
                                                  [weakSelf ingestFrame:pb dirty:dirty count:n epoch:epoch];
                                                }];
    __weak MSCapture *weakCap = cap;
    cap.stoppedWithError = ^(NSError *error) {
      MSController *s = weakSelf;
      if (!s || s->_capture != weakCap) return;
      s->_capture = nil;
      [s scheduleCaptureRetry:1.0];
    };
    [cap startWithCompletion:^(NSError *error) {
      MSController *s = weakSelf;
      if (!s) return;
      s->_captureStarting = NO;
      if (!error && (!s->_vd || s->_vd.displayID != cap.displayID || [s captureEpoch] != epoch)) {
          // The display was replaced or the frames were discarded while starting
          // (startCapture calls meanwhile returned early): start over. A failed
          // start goes through the usual error handling below instead.
          [cap stopWithCompletion:nil];
          [s startCapture];
          return;
      }
      if (error) {
          BOOL denied = [error.domain isEqualToString:SCStreamErrorDomain] && error.code == SCStreamErrorUserDeclined;
          // A new virtual display shows up in ScreenCaptureKit a moment later: retry quietly.
          BOOL notYet = [error.domain isEqualToString:MSCaptureErrorDomain] &&
                        error.code == MSCaptureErrorDisplayNotFound && s->_notFoundRetries++ < 10;
          NSString *msg = [NSString stringWithFormat:@"%@ %ld: %@", error.domain, (long)error.code,
                                                     error.localizedDescription];
          if (!notYet && ![msg isEqualToString:s->_lastCaptureError])
              msx_log("capture start failed: %s", msg.UTF8String);
          s->_lastCaptureError = msg;
          if (denied) {
              // The silent check says yes but ScreenCaptureKit refuses: the grant
              // usually takes effect only after a relaunch. No automatic retry here,
              // every refused ScreenCaptureKit call pops up a system dialog. The
              // display would stay dark meanwhile, so it goes away.
              s->_captureDenied = YES;
              s->_needsRelaunch = YES;
              [s removeDisplay];
              [s notify];
              return;
          }
          // Right after wake the display may not be capturable yet: retry quickly.
          [s scheduleCaptureRetry:now_s() - s->_wakeTime < 3 ? 0.1 : 0.5];
          return;
      }
      s->_notFoundRetries = 0;
      s->_lastCaptureError = nil;
      s->_captureDenied = NO;
      s->_capture = cap;
      [s notify];
      // A mode change while starting went unnoticed (no capture to restart then).
      [s displayReconfigured:cap.displayID];
    }];
}

- (uint64_t)captureEpoch {
    pthread_mutex_lock(&_fl);
    uint64_t e = _captureEpoch;
    pthread_mutex_unlock(&_fl);
    return e;
}

// A fresh stream starts with a complete frame, even if nothing changes on screen.
- (void)restartCapture {
    MSCapture *old = _capture;
    _capture = nil;
    [old stopWithCompletion:^{
      [self startCapture];
    }];
    if (!old) [self startCapture];
}

// Without permission every ScreenCaptureKit call shows a system dialog, so ask
// once per launch and afterwards only poll the silent preflight check. The
// virtual display exists only while the permission does.
- (void)waitForPermission {
    if (_vd) {
        // Not expected: a running app keeps the permission until it quits, even
        // after it is switched off (checked 17.10.2026). Keep the rule anyway.
        msx_log("Screen Recording permission gone, removing the virtual display");
        _accessRequested = YES;
        [self removeDisplay];
    } else if (!_captureDenied) {
        msx_log("no Screen Recording permission, waiting for it before creating the virtual display");
    }
    _captureDenied = YES;
    [self notify];
    if (!_accessRequested) {
        _accessRequested = YES;
        CGRequestScreenCaptureAccess();
    }
    [self scheduleCaptureRetry:2.0];
}

- (BOOL)needsRelaunch {
    return _needsRelaunch;
}

- (void)scheduleCaptureRetry:(double)delay {
    if (_retryScheduled) return;
    _retryScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      self->_retryScheduled = NO;
      if (self->_vd)
          [self startCapture];
      else
          [self syncDisplay];  // no display yet: permission, failed creation or removed by the system
    });
}

- (void)displayReconfigured:(CGDirectDisplayID)display {
    if (!_vd || display != _vd.displayID || !_capture) return;
    CGSize size = [self currentSize];
    if (CGSizeEqualToSize(size, _capture.size) || CGSizeEqualToSize(size, CGSizeZero)) return;
    msx_log("display mode changed to %.0fx%.0f, restarting capture", size.width, size.height);
    [self restartCapture];
}

static void display_reconfigured(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *ctx) {
    if (flags & kCGDisplayBeginConfigurationFlag) return;
    MSController *controller = (__bridge MSController *)ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
      [controller displayReconfigured:display];
    });
}

#pragma mark - Modes

- (NSArray<NSValue *> *)supportedSizes {
    int count = 0;
    const ms_mode *modes = ms_mode_table(&count);
    NSMutableArray *sizes = [NSMutableArray array];
    for (int i = 0; i < count; i++) [sizes addObject:[NSValue valueWithSize:NSMakeSize(modes[i].width, modes[i].height)]];
    return sizes;
}

- (CGSize)currentSize {
    if (!_displayID) return CGSizeZero;
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(_displayID);
    if (!mode) return CGSizeZero;
    CGSize s = CGSizeMake(CGDisplayModeGetPixelWidth(mode), CGDisplayModeGetPixelHeight(mode));
    CGDisplayModeRelease(mode);
    return s;
}

- (void)selectSize:(CGSize)size {
    if (!_displayID) return;
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(_displayID, NULL);
    if (!modes) return;
    for (CFIndex i = 0; i < CFArrayGetCount(modes); i++) {
        CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        if (CGDisplayModeGetPixelWidth(m) != (size_t)size.width || CGDisplayModeGetPixelHeight(m) != (size_t)size.height)
            continue;
        CGDisplayConfigRef cfg;
        if (CGBeginDisplayConfiguration(&cfg) != kCGErrorSuccess) break;
        CGConfigureDisplayWithDisplayMode(cfg, _displayID, m, NULL);
        CGError err = CGCompleteDisplayConfiguration(cfg, kCGConfigurePermanently);
        msx_log("switch to %.0fx%.0f: %s", size.width, size.height, err == kCGErrorSuccess ? "ok" : "failed");
        break;
    }
    CFRelease(modes);
}

@end
