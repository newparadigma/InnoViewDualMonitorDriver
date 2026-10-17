// MacroSilicon MS9132 USB display protocol (user-space, IOKit IOUSBLib).
//
// Protocol sources:
//  - reverse engineered Linux driver ms912x (github.com/rhgndf/ms912x, GPL-2.0)
//  - command sequence of the vendor macOS driver 3.3.1.56 (UsbDisplayDevice),
//    which is known to work with the InnoView INVPM009 dual-screen monitor.
//
// Device layout (345f:9132): interface 0 is HID (owned by macOS), control
// requests go through the default pipe with wIndex 0; pixels go to the bulk
// OUT endpoint 0x04 of interface 3 (class 0xFF).
//
// Not thread-safe: one ms_dev must be used from one thread at a time.
#ifndef MS9132_H
#define MS9132_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Errors: negative IOReturn codes are passed through, plus our own:
#define MS_ERR_NOT_FOUND   (-1000)  // no supported device present
#define MS_ERR_BUSY        (-1001)  // device/interface opened by someone else (vendor driver?)
#define MS_ERR_HID_TIMEOUT (-1002)  // device did not acknowledge a command
#define MS_ERR_BAD_MODE    (-1003)
#define MS_ERR_NO_ENDPOINT (-1004)  // no bulk OUT endpoint on a vendor interface

// Pixel formats understood by the chip (video_in "color" byte).
#define MS_PIXFMT_RGB888 0x11  // experimental, 3 bytes per pixel
#define MS_PIXFMT_UYVY   0x22  // YUV 4:2:2, 2 bytes per pixel (vendor default)

#define MS_FRAME_HEADER  8
#define MS_FRAME_TRAILER 8
#define MS_FRAME_OVERHEAD (MS_FRAME_HEADER + MS_FRAME_TRAILER)

// Horizontal granularity of update rectangles. ms912x sends x and width in
// units of 16 pixels, the vendor driver packs them as 12-bit values; for
// multiples of 16 both encodings produce identical bytes.
#define MS_RECT_ALIGN 16

typedef struct ms_dev ms_dev;

typedef struct {
    int width;
    int height;
    int hz;
    uint8_t vic;  // mode number understood by the chip
} ms_mode;

typedef struct {
    uint16_t vid, pid;
    int usb_speed;           // 2 = USB 2.0 (480 Mbit/s), 3 = USB 3.x, 0 = unknown
    uint8_t chip_raw[3];     // bytes at 0xFF00
    int video_port;          // 5 = HDMI
    int interface_number;    // interface carrying the bulk endpoint
    uint8_t endpoint;        // bulk OUT endpoint address
    uint16_t max_packet;
} ms_info;

typedef void (*ms_log_fn)(const char *line);

// Global init (call once). Log callback may be NULL.
int ms_global_init(ms_log_fn log);
void ms_global_exit(void);

// Returns 1 if a supported device is currently plugged in (cheap check).
int ms_device_present(void);

// Open the first supported device, claim its vendor interface and read chip id
// and video port.
int ms_open(ms_dev **out);
void ms_close(ms_dev *dev);
const ms_info *ms_get_info(const ms_dev *dev);

// Register access.
int ms_read_byte(ms_dev *dev, uint16_t addr, uint8_t *value);
int ms_write_byte(ms_dev *dev, uint16_t addr, uint8_t value);

// Reads up to 256 bytes of EDID (block 0 + optional block 1). Returns bytes read or <0.
int ms_read_edid(ms_dev *dev, uint8_t edid[256]);

// Status register 0x32 (polled every 500 ms by the vendor driver):
#define MS_STATUS_HPD     0x01  // monitor connected
#define MS_STATUS_ROTATED 0x04  // panel is upside down (orientation sensor): flip the picture 180 degrees

// HPD: 1 = sink connected, 0 = not, <0 error. raw (optional) gets the register value.
int ms_hpd(ms_dev *dev, uint8_t *raw);

// High level steps (same order as the vendor driver).
int ms_power_on(ms_dev *dev, int on);
int ms_video_on(ms_dev *dev, int on);
int ms_screen_on(ms_dev *dev, int on);
// transfer_mode(3) + video_in + video_out + start_trans(1)
int ms_configure_stream(ms_dev *dev, const ms_mode *mode, uint8_t pixfmt);
// screen_on(0) + video_on(0)
int ms_stop_stream(ms_dev *dev);

// Mode table lookup (NULL if unsupported). hz 0 matches any refresh rate.
const ms_mode *ms_find_mode(int width, int height, int hz);
const ms_mode *ms_mode_table(int *count);

// Frame packet: [header 8][pixels][trailer 8]. Rect x and width must be even for UYVY.
void ms_write_header(uint8_t *dst, int x, int y, int w, int h);
void ms_write_trailer(uint8_t *dst);

// Bulk send of a complete packet. Returns 0 on success.
int ms_send(ms_dev *dev, const uint8_t *buf, int len, unsigned timeout_ms);

const char *ms_strerror(int err);

#ifdef __cplusplus
}
#endif
#endif
