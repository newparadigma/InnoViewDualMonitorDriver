// MacroSilicon MS9132 protocol over IOKit IOUSBLib. See ms9132.h.
#include "ms9132.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <mach/mach_error.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MS_VID 0x345f
#define MS_PID 0x9132

#define HID_TIMEOUT_MS 1000
#define WAIT_TRIES 100
#define WAIT_DELAY_US 10000

// Registers
#define REG_VIDEO_PORT 0x0031
#define REG_HPD        0x0032
#define REG_SCREEN     0xFB07  // bit 0x02 = screen off (9132, HDMI port)
#define REG_EDID       0xC000
#define REG_CHIP_ID    0xFF00

// Command acknowledge registers (become 0 when the command is done)
#define ACK_POWER      0xC454
#define ACK_VIDEO_ON   0x118D
#define ACK_TRANSFER   0x1026
#define ACK_VIDEO_IN   0x1123
#define ACK_VIDEO_OUT  0x1125

typedef IOUSBDeviceInterface942 **usb_dev_t;
typedef IOUSBInterfaceInterface942 **usb_intf_t;

struct ms_dev {
    usb_dev_t udev;
    usb_intf_t intf;
    int dev_open;
    UInt8 pipe;  // pipe reference of the bulk OUT endpoint
    ms_info info;
};

static ms_log_fn g_log;

static void mslog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void mslog(const char *fmt, ...) {
    if (!g_log) return;
    char line[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    g_log(line);
}

int ms_global_init(ms_log_fn log) {
    g_log = log;
    return 0;
}

void ms_global_exit(void) { g_log = NULL; }

// ---------------------------------------------------------------------------
// Device discovery / open

static io_service_t find_service(void) {
    CFMutableDictionaryRef m = IOServiceMatching(kIOUSBHostDeviceClassName);
    if (!m) return IO_OBJECT_NULL;
    int vid = MS_VID, pid = MS_PID;
    CFNumberRef v = CFNumberCreate(NULL, kCFNumberIntType, &vid);
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    CFDictionarySetValue(m, CFSTR("idVendor"), v);
    CFDictionarySetValue(m, CFSTR("idProduct"), p);
    CFRelease(v);
    CFRelease(p);
    return IOServiceGetMatchingService(kIOMainPortDefault, m);  // consumes m
}

int ms_device_present(void) {
    io_service_t s = find_service();
    if (!s) return 0;
    IOObjectRelease(s);
    return 1;
}

static void *query_plugin(io_service_t svc, CFUUIDRef type, CFUUIDRef iid, IOReturn *err) {
    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    IOReturn kr = IOCreatePlugInInterfaceForService(svc, type, kIOCFPlugInInterfaceID, &plug, &score);
    if (kr != kIOReturnSuccess || !plug) {
        *err = kr != kIOReturnSuccess ? kr : kIOReturnError;
        return NULL;
    }
    void *obj = NULL;
    HRESULT hr = (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(iid), &obj);
    IODestroyPlugInInterface(plug);
    if (hr != S_OK || !obj) {
        *err = kIOReturnUnsupported;
        return NULL;
    }
    *err = kIOReturnSuccess;
    return obj;
}

// Opens the first vendor-class interface that has a bulk OUT endpoint.
static int open_vendor_interface(ms_dev *d) {
    IOUSBFindInterfaceRequest req = {
        .bInterfaceClass = kIOUSBFindInterfaceDontCare,
        .bInterfaceSubClass = kIOUSBFindInterfaceDontCare,
        .bInterfaceProtocol = kIOUSBFindInterfaceDontCare,
        .bAlternateSetting = kIOUSBFindInterfaceDontCare,
    };
    io_iterator_t it = IO_OBJECT_NULL;
    IOReturn kr = (*d->udev)->CreateInterfaceIterator(d->udev, &req, &it);
    if (kr != kIOReturnSuccess) return (int)kr;

    int result = MS_ERR_NO_ENDPOINT;
    io_service_t svc;
    while ((svc = IOIteratorNext(it)) != IO_OBJECT_NULL) {
        IOReturn qerr;
        usb_intf_t intf = query_plugin(svc, kIOUSBInterfaceUserClientTypeID, kIOUSBInterfaceInterfaceID942, &qerr);
        IOObjectRelease(svc);
        if (!intf) continue;

        UInt8 cls = 0, num = 0;
        (*intf)->GetInterfaceClass(intf, &cls);
        (*intf)->GetInterfaceNumber(intf, &num);
        if (cls != kUSBVendorSpecificInterfaceClass) {
            (*intf)->Release(intf);
            continue;
        }
        kr = (*intf)->USBInterfaceOpen(intf);
        if (kr != kIOReturnSuccess) {
            mslog("interface %u open failed: %s (0x%08x)", num, mach_error_string(kr), kr);
            (*intf)->Release(intf);
            result = kr == kIOReturnExclusiveAccess ? MS_ERR_BUSY : (int)kr;
            continue;
        }
        UInt8 neps = 0;
        (*intf)->GetNumEndpoints(intf, &neps);
        for (UInt8 pipe = 1; pipe <= neps; pipe++) {
            UInt8 dir = 0, epnum = 0, tt = 0, interval = 0;
            UInt16 mps = 0;
            if ((*intf)->GetPipeProperties(intf, pipe, &dir, &epnum, &tt, &mps, &interval) != kIOReturnSuccess)
                continue;
            if (dir == kUSBOut && tt == kUSBBulk) {
                d->intf = intf;
                d->pipe = pipe;
                d->info.interface_number = num;
                d->info.endpoint = epnum;
                d->info.max_packet = mps;
                IOObjectRelease(it);
                return 0;
            }
        }
        (*intf)->USBInterfaceClose(intf);
        (*intf)->Release(intf);
    }
    IOObjectRelease(it);
    return result;
}

int ms_open(ms_dev **out) {
    *out = NULL;
    io_service_t svc = find_service();
    if (!svc) return MS_ERR_NOT_FOUND;

    ms_dev *d = calloc(1, sizeof *d);
    if (!d) {
        IOObjectRelease(svc);
        return (int)kIOReturnNoMemory;
    }
    IOReturn kr;
    d->udev = query_plugin(svc, kIOUSBDeviceUserClientTypeID, kIOUSBDeviceInterfaceID942, &kr);
    IOObjectRelease(svc);
    if (!d->udev) {
        free(d);
        return (int)kr;
    }

    kr = (*d->udev)->USBDeviceOpen(d->udev);
    if (kr != kIOReturnSuccess) {
        ms_close(d);
        return kr == kIOReturnExclusiveAccess ? MS_ERR_BUSY : (int)kr;
    }
    d->dev_open = 1;

    (*d->udev)->GetDeviceVendor(d->udev, &d->info.vid);
    (*d->udev)->GetDeviceProduct(d->udev, &d->info.pid);
    UInt8 speed = 0;
    if ((*d->udev)->GetDeviceSpeed(d->udev, &speed) == kIOReturnSuccess)
        d->info.usb_speed = speed >= kUSBDeviceSpeedSuper ? 3 : speed == kUSBDeviceSpeedHigh ? 2 : 1;

    UInt8 cfg = 0;
    (*d->udev)->GetConfiguration(d->udev, &cfg);
    if (cfg == 0) {
        IOUSBConfigurationDescriptorPtr desc = NULL;
        kr = (*d->udev)->GetConfigurationDescriptorPtr(d->udev, 0, &desc);
        if (kr == kIOReturnSuccess && desc) kr = (*d->udev)->SetConfiguration(d->udev, desc->bConfigurationValue);
        if (kr != kIOReturnSuccess) {
            mslog("set configuration failed: %s (0x%08x)", mach_error_string(kr), kr);
            ms_close(d);
            return (int)kr;
        }
    }

    int r = open_vendor_interface(d);
    if (r < 0) {
        ms_close(d);
        return r;
    }

    for (int i = 0; i < 3; i++) {
        r = ms_read_byte(d, REG_CHIP_ID + i, &d->info.chip_raw[i]);
        if (r < 0) {
            ms_close(d);
            return r;
        }
    }
    uint8_t port = 0;
    r = ms_read_byte(d, REG_VIDEO_PORT, &port);
    if (r < 0) {
        ms_close(d);
        return r;
    }
    d->info.video_port = port;

    mslog("opened %04x:%04x, USB %s, chip id %02X%02X%02X, video port %d, interface %d ep 0x%02x mps %u",
          d->info.vid, d->info.pid, d->info.usb_speed == 3 ? "3.x" : d->info.usb_speed == 2 ? "2.0" : "1.x",
          d->info.chip_raw[0], d->info.chip_raw[1], d->info.chip_raw[2], d->info.video_port,
          d->info.interface_number, d->info.endpoint, d->info.max_packet);
    *out = d;
    return 0;
}

void ms_close(ms_dev *d) {
    if (!d) return;
    if (d->intf) {
        (*d->intf)->USBInterfaceClose(d->intf);
        (*d->intf)->Release(d->intf);
    }
    if (d->udev) {
        if (d->dev_open) (*d->udev)->USBDeviceClose(d->udev);
        (*d->udev)->Release(d->udev);
    }
    free(d);
}

const ms_info *ms_get_info(const ms_dev *d) { return &d->info; }

// ---------------------------------------------------------------------------
// HID transport: 8-byte feature report 0 via SET_REPORT / GET_REPORT

static int hid_request(ms_dev *d, uint8_t type, uint8_t request, uint8_t report[8]) {
    IOUSBDevRequestTO req = {
        .bmRequestType = type,
        .bRequest = request,
        .wValue = 0x0300,
        .wIndex = 0,
        .wLength = 8,
        .pData = report,
        .noDataTimeout = HID_TIMEOUT_MS,
        .completionTimeout = HID_TIMEOUT_MS,
    };
    IOReturn kr = (*d->udev)->DeviceRequestTO(d->udev, &req);
    return kr == kIOReturnSuccess ? 0 : (int)kr;
}

static int hid_set(ms_dev *d, const uint8_t report[8]) {
    uint8_t buf[8];
    memcpy(buf, report, 8);
    return hid_request(d, 0x21, 0x09, buf);
}

static int hid_get(ms_dev *d, uint8_t report[8]) {
    memset(report, 0, 8);
    return hid_request(d, 0xA1, 0x01, report);
}

int ms_read_byte(ms_dev *d, uint16_t addr, uint8_t *value) {
    uint8_t rep[8] = {0xB5, addr >> 8, addr & 0xFF};
    int r = hid_set(d, rep);
    if (r < 0) return r;
    r = hid_get(d, rep);
    if (r < 0) return r;
    *value = rep[3];
    return 0;
}

int ms_write_byte(ms_dev *d, uint16_t addr, uint8_t value) {
    uint8_t rep[8] = {0xB6, addr >> 8, addr & 0xFF, value};
    return hid_set(d, rep);
}

static int wait_done(ms_dev *d, uint16_t addr) {
    for (int i = 0; i < WAIT_TRIES; i++) {
        uint8_t v = 0xFF;
        int r = ms_read_byte(d, addr, &v);
        if (r < 0) return r;
        if (v == 0) return 0;
        usleep(WAIT_DELAY_US);
    }
    mslog("register 0x%04x did not clear", addr);
    return MS_ERR_HID_TIMEOUT;
}

// [A6 cmd d0..d5], then wait for ack register (0 = don't wait).
static int command(ms_dev *d, uint8_t cmd, const uint8_t *data, int n, uint16_t ack) {
    uint8_t rep[8] = {0xA6, cmd};
    memcpy(rep + 2, data, n);
    int r = hid_set(d, rep);
    if (r < 0) return r;
    return ack ? wait_done(d, ack) : 0;
}

// ---------------------------------------------------------------------------
// High level

int ms_read_edid(ms_dev *d, uint8_t edid[256]) {
    memset(edid, 0, 256);
    int len = 128;
    for (int i = 0; i < len; i++) {
        int r = ms_read_byte(d, REG_EDID + i, &edid[i]);
        if (r < 0) return r;
        if (i == 126 && edid[126] > 0) len = 256;
    }
    return len;
}

int ms_hpd(ms_dev *d, uint8_t *raw) {
    uint8_t v = 0;
    int r = ms_read_byte(d, REG_HPD, &v);
    if (r < 0) return r;
    if (raw) *raw = v;
    return (v & MS_STATUS_HPD) != 0;
}

int ms_power_on(ms_dev *d, int on) {
    uint8_t data[] = {on ? 1 : 0, 0x02};
    return command(d, 0x07, data, sizeof data, ACK_POWER);
}

int ms_video_on(ms_dev *d, int on) {
    uint8_t data[] = {on ? 1 : 0};
    return command(d, 0x05, data, sizeof data, ACK_VIDEO_ON);
}

int ms_screen_on(ms_dev *d, int on) {
    if (d->info.video_port != 5) return 0;  // only known for 9132 + HDMI
    uint8_t v = 0;
    int r = ms_read_byte(d, REG_SCREEN, &v);
    if (r < 0) return r;
    uint8_t nv = on ? (v & ~0x02) : (v | 0x02);
    return nv == v ? 0 : ms_write_byte(d, REG_SCREEN, nv);
}

int ms_configure_stream(ms_dev *d, const ms_mode *m, uint8_t pixfmt) {
    if (!m) return MS_ERR_BAD_MODE;
    int r;
    uint8_t mode[] = {3};
    if ((r = command(d, 0x03, mode, sizeof mode, ACK_TRANSFER)) < 0) return r;

    uint8_t in[] = {m->width >> 8, m->width & 0xFF, m->height >> 8, m->height & 0xFF, pixfmt, 0};
    if ((r = command(d, 0x01, in, sizeof in, ACK_VIDEO_IN)) < 0) return r;

    uint8_t outp[] = {m->vic, 0x00, m->width >> 8, m->width & 0xFF, m->height >> 8, m->height & 0xFF};
    if ((r = command(d, 0x02, outp, sizeof outp, ACK_VIDEO_OUT)) < 0) return r;

    uint8_t start[] = {1};
    if ((r = command(d, 0x04, start, sizeof start, 0)) < 0) return r;
    mslog("stream configured: %dx%d@%d vic 0x%02x fmt 0x%02x", m->width, m->height, m->hz, m->vic, pixfmt);
    return 0;
}

int ms_stop_stream(ms_dev *d) {
    int r1 = ms_screen_on(d, 0);
    int r2 = ms_video_on(d, 0);
    return r1 < 0 ? r1 : r2;
}

static const ms_mode k_modes[] = {
    {1920, 1080, 60, 0x81},
    {1280, 720, 60, 0x4f},
};

const ms_mode *ms_mode_table(int *count) {
    *count = (int)(sizeof k_modes / sizeof k_modes[0]);
    return k_modes;
}

const ms_mode *ms_find_mode(int width, int height, int hz) {
    for (size_t i = 0; i < sizeof k_modes / sizeof k_modes[0]; i++) {
        const ms_mode *m = &k_modes[i];
        if (m->width == width && m->height == height && (hz == 0 || m->hz == hz)) return m;
    }
    return NULL;
}

// ---------------------------------------------------------------------------
// Frames

void ms_write_header(uint8_t *p, int x, int y, int w, int h) {
    p[0] = 0xFF;
    p[1] = 0x00;
    p[2] = (x >> 4) & 0xFF;
    p[3] = ((x & 0x0F) << 4) | ((y >> 8) & 0x0F);
    p[4] = y & 0xFF;
    p[5] = (w >> 4) & 0xFF;
    p[6] = ((w & 0x0F) << 4) | ((h >> 8) & 0x0F);
    p[7] = h & 0xFF;
}

void ms_write_trailer(uint8_t *p) {
    static const uint8_t t[MS_FRAME_TRAILER] = {0xFF, 0xC0, 0, 0, 0, 0, 0, 0};
    memcpy(p, t, sizeof t);
}

int ms_send(ms_dev *d, const uint8_t *buf, int len, unsigned timeout_ms) {
    IOReturn kr = (*d->intf)->WritePipeTO(d->intf, d->pipe, (void *)buf, (UInt32)len, timeout_ms, timeout_ms);
    if (kr == kIOReturnSuccess) return 0;
    if (kr == kIOUSBTransactionTimeout || kr == kIOReturnTimeout) (*d->intf)->AbortPipe(d->intf, d->pipe);
    if (kr == kIOUSBPipeStalled || kr == kIOUSBTransactionTimeout || kr == kIOReturnTimeout)
        (*d->intf)->ClearPipeStallBothEnds(d->intf, d->pipe);
    return (int)kr;
}

const char *ms_strerror(int err) {
    switch (err) {
    case 0: return "ok";
    case MS_ERR_NOT_FOUND: return "device not found";
    case MS_ERR_BUSY: return "device is used by another program (vendor driver?)";
    case MS_ERR_HID_TIMEOUT: return "device did not acknowledge command";
    case MS_ERR_BAD_MODE: return "unsupported mode";
    case MS_ERR_NO_ENDPOINT: return "no bulk endpoint";
    default: return mach_error_string((mach_error_t)err);
    }
}
