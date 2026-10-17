// Command line diagnostics:
//   InnoViewDualMonitorDriver --probe                    chip id, USB speed, HPD, EDID (no state changes)
//   InnoViewDualMonitorDriver --pattern [seconds] [full] color bars + moving box straight to the chip
#include "tools.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "frame.h"
#include "log.h"
#include "ms9132.h"

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static int open_dev(ms_dev **dev) {
    ms_global_init(msx_log_line);
    int r = ms_open(dev);
    if (r < 0) msx_log("open failed: %s (%d)", ms_strerror(r), r);
    return r;
}

static void log_edid(ms_dev *dev) {
    uint8_t edid[256];
    int n = ms_read_edid(dev, edid);
    if (n < 0) {
        msx_log("EDID read failed: %s", ms_strerror(n));
        return;
    }
    static const uint8_t hdr[8] = {0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0};
    msx_log_hex(memcmp(edid, hdr, 8) == 0 ? "EDID:" : "EDID (bad header):", edid, n);
    for (int d = 54; d <= 108; d += 18)
        if (edid[d] == 0 && edid[d + 1] == 0 && edid[d + 3] == 0xFC) {
            char name[14] = {0};
            for (int i = 0; i < 13 && edid[d + 5 + i] != '\n'; i++) name[i] = (char)edid[d + 5 + i];
            msx_log("monitor name: %s", name);
        }
}

int msx_probe(void) {
    ms_dev *dev;
    if (open_dev(&dev) < 0) return 1;
    uint8_t hpd = 0, scr = 0;
    int r = ms_hpd(dev, &hpd);
    msx_log("status 0x%02x: HPD %d, %s", hpd, r, hpd & MS_STATUS_ROTATED ? "panel upside down" : "panel upright");
    if (ms_read_byte(dev, 0xFB07, &scr) == 0) msx_log("reg 0xFB07: 0x%02x (screen %s)", scr, scr & 2 ? "off" : "on");
    log_edid(dev);
    ms_close(dev);
    return 0;
}

// --- test pattern ---------------------------------------------------------

#define W 1920
#define H 1080
#define BOX 160

static void put(uint8_t *img, int x, int y, uint32_t rgb) {
    uint8_t *p = img + ((size_t)y * W + x) * 4;
    p[0] = rgb & 0xFF;
    p[1] = (rgb >> 8) & 0xFF;
    p[2] = (rgb >> 16) & 0xFF;
    p[3] = 0xFF;
}

static uint32_t background(int x, int y) {
    static const uint32_t bars[8] = {0xFFFFFF, 0xFFFF00, 0x00FFFF, 0x00FF00, 0xFF00FF, 0xFF0000, 0x0000FF, 0x000000};
    if (y < H * 2 / 3) return bars[x * 8 / W];
    uint32_t g = (uint32_t)(x * 255 / (W - 1));
    if (y < H * 5 / 6) return g << 16 | g << 8 | g;  // grey ramp
    return (x / 16 + y / 16) & 1 ? 0xFFFFFF : 0x000000;  // 16 px checkerboard
}

static void draw_bg(uint8_t *img, ms_rect r) {
    for (int y = r.y; y < r.y + r.h; y++)
        for (int x = r.x; x < r.x + r.w; x++) put(img, x, y, background(x, y));
}

static void draw_box(uint8_t *img, int bx, int by) {
    for (int y = by; y < by + BOX; y++)
        for (int x = bx; x < bx + BOX; x++) {
            int edge = x < bx + 4 || y < by + 4 || x >= bx + BOX - 4 || y >= by + BOX - 4;
            put(img, x, y, edge ? 0x000000 : 0xFF8000);
        }
}

int msx_pattern(int seconds, int full) {
    ms_dev *dev;
    if (open_dev(&dev) < 0) return 1;
    int rc = 1;
    uint8_t *img = malloc((size_t)W * H * 4);
    uint8_t *yuv = malloc((size_t)W * H * 2);
    uint8_t *pkt = malloc(ms_packet_size(W, H, 2));
    if (!img || !yuv || !pkt || ms_frame_init() < 0) goto out;

    int r;
    if ((r = ms_power_on(dev, 1)) < 0 || (r = ms_video_on(dev, 0)) < 0 || (r = ms_screen_on(dev, 0)) < 0) {
        msx_log("init failed: %s", ms_strerror(r));
        goto out;
    }
    double t0 = now_s();
    while ((r = ms_hpd(dev, NULL)) == 0 && now_s() - t0 < 5) usleep(100000);
    if (r <= 0) {
        msx_log("no HPD: %s", r < 0 ? ms_strerror(r) : "monitor not connected");
        goto out;
    }
    log_edid(dev);
    if ((r = ms_configure_stream(dev, ms_find_mode(W, H, 60), MS_PIXFMT_UYVY)) < 0) {
        msx_log("configure failed: %s", ms_strerror(r));
        goto out;
    }

    ms_rect all = ms_rect_full(W, H);
    draw_bg(img, all);
    int bx = 100, by = 100, dx = 7, dy = 5;
    draw_box(img, bx, by);
    ms_convert_rect(img, W * 4, yuv, W * 2, all, MS_PIXFMT_UYVY);

    ms_rect prev_dirty = all, dirty = all;
    double start = now_s(), last_report = start;
    long frames = 0, bytes = 0, frames_window = 0, bytes_window = 0;
    while (now_s() - start < seconds) {
        ms_rect send = full ? all : ms_rect_union(dirty, prev_dirty);
        size_t len = ms_build_packet(pkt, yuv, W * 2, 2, send);
        double ts = now_s();
        if ((r = ms_send(dev, pkt, (int)len, 3000)) < 0) {
            msx_log("send failed: %s (0x%08x)", ms_strerror(r), r);
            goto out;
        }
        double te = now_s();
        if (frames == 0) {
            ms_screen_on(dev, 1);
            ms_video_on(dev, 1);
            msx_log("first frame %zu bytes in %.1f ms, screen on", len, (te - ts) * 1000);
        }
        frames++, frames_window++;
        bytes += len, bytes_window += len;
        if (te - last_report >= 1) {
            msx_log("%.1f fps, %.1f MB/s, last transfer %d,%d %dx%d", frames_window / (te - last_report),
                    bytes_window / (te - last_report) / 1e6, send.x, send.y, send.w, send.h);
            frames_window = bytes_window = 0;
            last_report = te;
        }

        // Move the box, then convert only what changed.
        ms_rect old = {bx, by, BOX, BOX};
        if (bx + dx < 0 || bx + dx + BOX > W) dx = -dx;
        if (by + dy < 0 || by + dy + BOX > H) dy = -dy;
        bx += dx, by += dy;
        draw_bg(img, old);
        draw_box(img, bx, by);
        prev_dirty = dirty;
        dirty = ms_rect_align(ms_rect_union(old, (ms_rect){bx, by, BOX, BOX}), W, H);
        ms_convert_rect(img, W * 4, yuv, W * 2, dirty, MS_PIXFMT_UYVY);

        double spent = now_s() - ts;
        if (spent < 1.0 / 60) usleep((useconds_t)((1.0 / 60 - spent) * 1e6));
    }
    msx_log("done: %ld frames, %.1f MB", frames, bytes / 1e6);
    rc = 0;
out:
    ms_stop_stream(dev);
    ms_power_on(dev, 0);
    ms_close(dev);
    free(img);
    free(yuv);
    free(pkt);
    return rc;
}
