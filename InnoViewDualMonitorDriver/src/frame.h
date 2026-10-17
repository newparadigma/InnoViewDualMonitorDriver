// Pixel conversion (BGRA -> chip format) and packet assembly.
#ifndef FRAME_H
#define FRAME_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int x, y, w, h;
} ms_rect;

static inline int ms_rect_empty(ms_rect r) { return r.w <= 0 || r.h <= 0; }
static inline ms_rect ms_rect_full(int w, int h) { return (ms_rect){0, 0, w, h}; }
ms_rect ms_rect_union(ms_rect a, ms_rect b);
// Clamp to [0,w)x[0,h) and widen horizontally to MS_RECT_ALIGN.
ms_rect ms_rect_align(ms_rect r, int w, int h);

int ms_frame_init(void);
int ms_bytes_per_pixel(uint8_t pixfmt);

// Where rect r of a w x h image lands after rotating the image by 180 degrees.
static inline ms_rect ms_rect_rot180(ms_rect r, int w, int h) {
    return (ms_rect){w - r.x - r.w, h - r.y - r.h, r.w, r.h};
}

// Converts rect r of a BGRA image into the same rect of dst (chip format).
// r must be aligned (see ms_rect_align).
int ms_convert_rect(const uint8_t *bgra, size_t src_stride, uint8_t *dst, size_t dst_stride, ms_rect r,
                    uint8_t pixfmt);

// Same, but the w x h image is rotated by 180 degrees (one pass): rect r of
// the source lands at ms_rect_rot180(r, w, h) in dst. r.w must be even.
int ms_convert_rect_rot180(const uint8_t *bgra, size_t src_stride, int w, int h, uint8_t *dst, size_t dst_stride,
                           ms_rect r, uint8_t pixfmt);

// Rotates a whole chip-format image by 180 degrees in place.
void ms_rotate180_inplace(uint8_t *img, int w, int h, uint8_t pixfmt);

// Writes [header][rows of r from img][trailer] to pkt. Returns packet length.
size_t ms_build_packet(uint8_t *pkt, const uint8_t *img, size_t stride, int bpp, ms_rect r);

static inline size_t ms_packet_size(int w, int h, int bpp) { return (size_t)w * h * bpp + 16; }

#ifdef __cplusplus
}
#endif
#endif
