#include "frame.h"

#include <Accelerate/Accelerate.h>
#include <string.h>
#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif

#include "ms9132.h"

static vImage_ARGBToYpCbCr g_yuv;
static int g_ready;

static int imin(int a, int b) { return a < b ? a : b; }
static int imax(int a, int b) { return a > b ? a : b; }

ms_rect ms_rect_union(ms_rect a, ms_rect b) {
    if (ms_rect_empty(a)) return b;
    if (ms_rect_empty(b)) return a;
    int x0 = imin(a.x, b.x), y0 = imin(a.y, b.y);
    int x1 = imax(a.x + a.w, b.x + b.w), y1 = imax(a.y + a.h, b.y + b.h);
    return (ms_rect){x0, y0, x1 - x0, y1 - y0};
}

ms_rect ms_rect_align(ms_rect r, int w, int h) {
    int x0 = imax(r.x, 0), y0 = imax(r.y, 0);
    int x1 = imin(r.x + r.w, w), y1 = imin(r.y + r.h, h);
    if (x1 <= x0 || y1 <= y0) return (ms_rect){0, 0, 0, 0};
    x0 &= ~(MS_RECT_ALIGN - 1);
    x1 = imin((x1 + MS_RECT_ALIGN - 1) & ~(MS_RECT_ALIGN - 1), w & ~1);
    return (ms_rect){x0, y0, x1 - x0, y1 - y0};
}

int ms_frame_init(void) {
    if (g_ready) return 0;
    // BT.601, limited range, as the vendor driver does.
    vImage_YpCbCrPixelRange range = {16, 128, 235, 240, 235, 16, 240, 16};
    vImage_Error e = vImageConvert_ARGBToYpCbCr_GenerateConversion(
        kvImage_ARGBToYpCbCrMatrix_ITU_R_601_4, &range, &g_yuv, kvImageARGB8888, kvImage422CbYpCrYp8, kvImageNoFlags);
    if (e != kvImageNoError) return (int)e;
    g_ready = 1;
    return 0;
}

int ms_bytes_per_pixel(uint8_t pixfmt) { return pixfmt == MS_PIXFMT_RGB888 ? 3 : 2; }

static int convert(const uint8_t *src_px, size_t src_stride, uint8_t *dst_px, size_t dst_stride, int w, int h,
                   uint8_t pixfmt) {
    vImage_Buffer src = {(void *)src_px, (vImagePixelCount)h, (vImagePixelCount)w, src_stride};
    vImage_Buffer out = {dst_px, (vImagePixelCount)h, (vImagePixelCount)w, dst_stride};
    vImage_Error e;
    if (pixfmt == MS_PIXFMT_RGB888) {
        e = vImageConvert_BGRA8888toRGB888(&src, &out, kvImageDoNotTile);
    } else {
        static const uint8_t bgra_to_argb[4] = {3, 2, 1, 0};
        e = vImageConvert_ARGB8888To422CbYpCrYp8(&src, &out, &g_yuv, bgra_to_argb, kvImageDoNotTile);
    }
    return e == kvImageNoError ? 0 : (int)e;
}

int ms_convert_rect(const uint8_t *bgra, size_t src_stride, uint8_t *dst, size_t dst_stride, ms_rect r,
                    uint8_t pixfmt) {
    if (ms_rect_empty(r)) return 0;
    int bpp = ms_bytes_per_pixel(pixfmt);
    return convert(bgra + (size_t)r.y * src_stride + (size_t)r.x * 4, src_stride,
                   dst + (size_t)r.y * dst_stride + (size_t)r.x * bpp, dst_stride, r.w, r.h, pixfmt);
}

// Rotated conversion in one pass: each output row is produced from a source
// row read backwards. Same result as vImage (BT.601 limited range, 4:2:2
// chroma = rounded average of the pixel pair; checked against it), but
// without a separate rotation pass over the BGRA data.
//
// Fixed point, Q14: Y  = 16  + (4207 R + 8260 G + 1604 B) / 2^14
//                   Cb = 128 + (-2428 R - 4768 G + 7196 B) / 2^14
//                   Cr = 128 + (7196 R - 6026 G - 1170 B) / 2^14
enum { YR = 4207, YG = 8260, YB = 1604, UR = -2428, UG = -4768, UB = 7196, VR = 7196, VG = -6026, VB = -1170 };

static inline uint8_t clamp_u8(int v) { return v < 0 ? 0 : v > 255 ? 255 : (uint8_t)v; }

// dst pixel i (UYVY) <- src pixel n-1-i (BGRA); n even.
static void row_uyvy_reversed(const uint8_t *src, int n, uint8_t *dst) {
    int i = 0;
#if defined(__ARM_NEON)
    for (; i + 16 <= n; i += 16) {
        uint8x16x4_t px = vld4q_u8(src + (size_t)(n - 16 - i) * 4);
        uint8x16_t b = vrev64q_u8(px.val[0]), g = vrev64q_u8(px.val[1]), r = vrev64q_u8(px.val[2]);
        b = vextq_u8(b, b, 8), g = vextq_u8(g, g, 8), r = vextq_u8(r, r, 8);

        uint16x8_t rl = vmovl_u8(vget_low_u8(r)), rh = vmovl_high_u8(r);
        uint16x8_t gl = vmovl_u8(vget_low_u8(g)), gh = vmovl_high_u8(g);
        uint16x8_t bl = vmovl_u8(vget_low_u8(b)), bh = vmovl_high_u8(b);
        uint32x4_t y0 = vmull_n_u16(vget_low_u16(rl), YR), y1 = vmull_high_n_u16(rl, YR);
        uint32x4_t y2 = vmull_n_u16(vget_low_u16(rh), YR), y3 = vmull_high_n_u16(rh, YR);
        y0 = vmlal_n_u16(y0, vget_low_u16(gl), YG), y1 = vmlal_high_n_u16(y1, gl, YG);
        y2 = vmlal_n_u16(y2, vget_low_u16(gh), YG), y3 = vmlal_high_n_u16(y3, gh, YG);
        y0 = vmlal_n_u16(y0, vget_low_u16(bl), YB), y1 = vmlal_high_n_u16(y1, bl, YB);
        y2 = vmlal_n_u16(y2, vget_low_u16(bh), YB), y3 = vmlal_high_n_u16(y3, bh, YB);
        uint16x8_t ylo = vcombine_u16(vrshrn_n_u32(y0, 14), vrshrn_n_u32(y1, 14));
        uint16x8_t yhi = vcombine_u16(vrshrn_n_u32(y2, 14), vrshrn_n_u32(y3, 14));
        uint8x16_t y = vaddq_u8(vcombine_u8(vmovn_u16(ylo), vmovn_u16(yhi)), vdupq_n_u8(16));

        // Sums of the pixel pairs (0..510); chroma = sum * coef / 2^15.
        int16x8_t rs = vreinterpretq_s16_u16(vpaddlq_u8(r));
        int16x8_t gs = vreinterpretq_s16_u16(vpaddlq_u8(g));
        int16x8_t bs = vreinterpretq_s16_u16(vpaddlq_u8(b));
        int32x4_t u0 = vmull_n_s16(vget_low_s16(rs), UR), u1 = vmull_high_n_s16(rs, UR);
        int32x4_t v0 = vmull_n_s16(vget_low_s16(rs), VR), v1 = vmull_high_n_s16(rs, VR);
        u0 = vmlal_n_s16(u0, vget_low_s16(gs), UG), u1 = vmlal_high_n_s16(u1, gs, UG);
        v0 = vmlal_n_s16(v0, vget_low_s16(gs), VG), v1 = vmlal_high_n_s16(v1, gs, VG);
        u0 = vmlal_n_s16(u0, vget_low_s16(bs), UB), u1 = vmlal_high_n_s16(u1, bs, UB);
        v0 = vmlal_n_s16(v0, vget_low_s16(bs), VB), v1 = vmlal_high_n_s16(v1, bs, VB);
        int16x8_t bias = vdupq_n_s16(128);
        uint8x8_t u = vqmovun_s16(vaddq_s16(vcombine_s16(vrshrn_n_s32(u0, 15), vrshrn_n_s32(u1, 15)), bias));
        uint8x8_t v = vqmovun_s16(vaddq_s16(vcombine_s16(vrshrn_n_s32(v0, 15), vrshrn_n_s32(v1, 15)), bias));

        uint8x8x4_t out = {{u, vget_low_u8(vuzp1q_u8(y, y)), v, vget_low_u8(vuzp2q_u8(y, y))}};
        vst4_u8(dst + (size_t)i * 2, out);
    }
#endif
    for (; i + 2 <= n; i += 2) {
        const uint8_t *p0 = src + (size_t)(n - 1 - i) * 4, *p1 = p0 - 4;
        int y0 = (YR * p0[2] + YG * p0[1] + YB * p0[0] + (1 << 13)) >> 14;
        int y1 = (YR * p1[2] + YG * p1[1] + YB * p1[0] + (1 << 13)) >> 14;
        int rs = p0[2] + p1[2], gs = p0[1] + p1[1], bs = p0[0] + p1[0];
        int u = (UR * rs + UG * gs + UB * bs + (1 << 14)) >> 15;
        int v = (VR * rs + VG * gs + VB * bs + (1 << 14)) >> 15;
        uint8_t *o = dst + (size_t)i * 2;
        o[0] = clamp_u8(128 + u), o[1] = (uint8_t)(16 + y0), o[2] = clamp_u8(128 + v), o[3] = (uint8_t)(16 + y1);
    }
}

// dst pixel i (R G B) <- src pixel n-1-i (BGRA).
static void row_rgb_reversed(const uint8_t *src, int n, uint8_t *dst) {
    int i = 0;
#if defined(__ARM_NEON)
    for (; i + 16 <= n; i += 16) {
        uint8x16x4_t px = vld4q_u8(src + (size_t)(n - 16 - i) * 4);
        uint8x16x3_t out;
        for (int c = 0; c < 3; c++) {
            uint8x16_t ch = vrev64q_u8(px.val[2 - c]);
            out.val[c] = vextq_u8(ch, ch, 8);
        }
        vst3q_u8(dst + (size_t)i * 3, out);
    }
#endif
    for (; i < n; i++) {
        const uint8_t *p = src + (size_t)(n - 1 - i) * 4;
        uint8_t *o = dst + (size_t)i * 3;
        o[0] = p[2], o[1] = p[1], o[2] = p[0];
    }
}

int ms_convert_rect_rot180(const uint8_t *bgra, size_t src_stride, int w, int h, uint8_t *dst, size_t dst_stride,
                           ms_rect r, uint8_t pixfmt) {
    if (ms_rect_empty(r)) return 0;
    ms_rect d = ms_rect_rot180(r, w, h);
    int bpp = ms_bytes_per_pixel(pixfmt);
    for (int j = 0; j < r.h; j++) {
        const uint8_t *s = bgra + (size_t)(r.y + r.h - 1 - j) * src_stride + (size_t)r.x * 4;
        uint8_t *o = dst + (size_t)(d.y + j) * dst_stride + (size_t)d.x * bpp;
        if (pixfmt == MS_PIXFMT_RGB888)
            row_rgb_reversed(s, r.w, o);
        else
            row_uyvy_reversed(s, r.w, o);
    }
    return 0;
}

// UYVY macropixel (U Y0 V Y1, little endian) with Y0 and Y1 swapped.
static inline uint32_t swap_luma(uint32_t m) {
    return (m & 0x00FF00FFu) | ((m >> 16) & 0x0000FF00u) | ((m << 16) & 0xFF000000u);
}

void ms_rotate180_inplace(uint8_t *img, int w, int h, uint8_t pixfmt) {
    size_t n = (size_t)w * h;
    if (n < 2) return;
    if (pixfmt == MS_PIXFMT_RGB888) {
        for (uint8_t *a = img, *b = img + (n - 1) * 3; a < b; a += 3, b -= 3)
            for (int i = 0; i < 3; i++) {
                uint8_t t = a[i];
                a[i] = b[i];
                b[i] = t;
            }
        return;
    }
    // Reversing the pixel order of the whole image is a 180 degree rotation.
    uint32_t *a = (uint32_t *)img, *b = a + n / 2 - 1;
    for (; a < b; a++, b--) {
        uint32_t t = swap_luma(*a);
        *a = swap_luma(*b);
        *b = t;
    }
    if (a == b) *a = swap_luma(*a);
}

size_t ms_build_packet(uint8_t *pkt, const uint8_t *img, size_t stride, int bpp, ms_rect r) {
    ms_write_header(pkt, r.x, r.y, r.w, r.h);
    uint8_t *p = pkt + MS_FRAME_HEADER;
    size_t row = (size_t)r.w * bpp;
    const uint8_t *s = img + (size_t)r.y * stride + (size_t)r.x * bpp;
    if (r.x == 0 && row == stride) {
        memcpy(p, s, row * r.h);
        p += row * r.h;
    } else {
        for (int y = 0; y < r.h; y++, s += stride, p += row) memcpy(p, s, row);
    }
    ms_write_trailer(p);
    return (size_t)(p - pkt) + MS_FRAME_TRAILER;
}
