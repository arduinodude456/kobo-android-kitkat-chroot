/*
 * SPDX-License-Identifier: MIT
 *
 * Pixel row conversion for the Kobo software EGL platform (platform_android_kobo.c).
 * No Mesa/Android dependency, so tests/host/test_convert.c can compile it on the host.
 *
 * Runs once per presented frame over every row, so it works on whole 32 bit words
 * (R<->B swizzle without per-byte branches) and has dedicated 565 <-> 8888 loops
 * instead of a decode/encode switch per pixel.  Little endian only (ARM, x86).
 */
#ifndef DROID_CONVERT_H
#define DROID_CONVERT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

/* Pixel layouts, named by the byte order in memory. */
enum droid_px {
   DROID_PX_NONE = 0,
   DROID_PX_RGBA,   /* HAL_PIXEL_FORMAT_RGBA_8888: bytes R,G,B,A */
   DROID_PX_RGBX,   /* HAL_PIXEL_FORMAT_RGBX_8888: bytes R,G,B,x */
   DROID_PX_BGRA,   /* HAL_PIXEL_FORMAT_BGRA_8888 / Mesa B8G8R8A8: bytes B,G,R,A */
   DROID_PX_BGRX,   /* Mesa B8G8R8X8: bytes B,G,R,x */
   DROID_PX_565,    /* HAL_PIXEL_FORMAT_RGB_565 / Mesa B5G6R5: little endian 16 bit */
};

static inline int
droid_px_bytes(enum droid_px px)
{
   switch (px) {
   case DROID_PX_RGBA:
   case DROID_PX_RGBX:
   case DROID_PX_BGRA:
   case DROID_PX_BGRX:
      return 4;
   case DROID_PX_565:
      return 2;
   default:
      return 0;
   }
}

static inline bool
droid_px_has_alpha(enum droid_px px)
{
   return px == DROID_PX_RGBA || px == DROID_PX_BGRA;
}

static inline bool
droid_px_is_bgr(enum droid_px px)
{
   return px == DROID_PX_BGRA || px == DROID_PX_BGRX;
}

static inline uint32_t
droid_ld32(const uint8_t *p)
{
   uint32_t v;
   memcpy(&v, p, 4);
   return v;
}

static inline void
droid_st32(uint8_t *p, uint32_t v)
{
   memcpy(p, &v, 4);
}

static inline uint16_t
droid_ld16(const uint8_t *p)
{
   uint16_t v;
   memcpy(&v, p, 2);
   return v;
}

static inline void
droid_st16(uint8_t *p, uint16_t v)
{
   memcpy(p, &v, 2);
}

/* 32 bit -> 32 bit: optional R<->B swap, optional forced opaque alpha. */
static void
droid_convert_32_32(uint8_t *dst, const uint8_t *src, int n, bool swap, bool opaque)
{
   const uint32_t or_mask = opaque ? 0xff000000u : 0;
   int i;

   if (swap) {
      for (i = 0; i < n; i++, src += 4, dst += 4) {
         uint32_t p = droid_ld32(src);
         droid_st32(dst, ((p & 0xff00ff00u) | ((p >> 16) & 0xffu) |
                          ((p & 0xffu) << 16)) | or_mask);
      }
   } else {
      for (i = 0; i < n; i++, src += 4, dst += 4)
         droid_st32(dst, droid_ld32(src) | or_mask);
   }
}

/* 32 bit -> RGB565 (truncating, like the original encoder). */
static void
droid_convert_32_565(uint8_t *dst, const uint8_t *src, int n, bool src_bgr)
{
   int i;

   if (src_bgr) {
      for (i = 0; i < n; i++, src += 4, dst += 2) {
         uint32_t p = droid_ld32(src);          /* x:A R:23..16 G:15..8 B:7..0 */
         droid_st16(dst, (uint16_t) (((p >> 8) & 0xf800u) | ((p >> 5) & 0x07e0u) |
                                     ((p >> 3) & 0x001fu)));
      }
   } else {
      for (i = 0; i < n; i++, src += 4, dst += 2) {
         uint32_t p = droid_ld32(src);          /* x:A B:23..16 G:15..8 R:7..0 */
         droid_st16(dst, (uint16_t) (((p << 8) & 0xf800u) | ((p >> 5) & 0x07e0u) |
                                     ((p >> 19) & 0x001fu)));
      }
   }
}

/* RGB565 -> 32 bit (bit replication, alpha 0xff). */
static void
droid_convert_565_32(uint8_t *dst, const uint8_t *src, int n, bool dst_bgr)
{
   int i;

   for (i = 0; i < n; i++, src += 2, dst += 4) {
      uint32_t p = droid_ld16(src);
      uint32_t r = (p >> 11) & 0x1fu, g = (p >> 5) & 0x3fu, b = p & 0x1fu;
      uint32_t r8 = (r << 3) | (r >> 2), g8 = (g << 2) | (g >> 4), b8 = (b << 3) | (b >> 2);

      droid_st32(dst, 0xff000000u | (g8 << 8) |
                      (dst_bgr ? ((r8 << 16) | b8) : ((b8 << 16) | r8)));
   }
}

/* Convert one row of n pixels.  X formats have an undefined alpha byte: it is
 * forced to 0xff whenever either side has no alpha. */
static void
droid_convert_row(enum droid_px dst_px, uint8_t *dst,
                  enum droid_px src_px, const uint8_t *src, int n)
{
   if (n <= 0)
      return;

   if (dst_px == src_px) {
      memcpy(dst, src, (size_t) n * droid_px_bytes(src_px));
      return;
   }

   if (droid_px_bytes(src_px) == 4 && droid_px_bytes(dst_px) == 4) {
      droid_convert_32_32(dst, src, n,
                          droid_px_is_bgr(src_px) != droid_px_is_bgr(dst_px),
                          !droid_px_has_alpha(src_px) || !droid_px_has_alpha(dst_px));
   } else if (droid_px_bytes(src_px) == 4 && dst_px == DROID_PX_565) {
      droid_convert_32_565(dst, src, n, droid_px_is_bgr(src_px));
   } else if (src_px == DROID_PX_565 && droid_px_bytes(dst_px) == 4) {
      droid_convert_565_32(dst, src, n, droid_px_is_bgr(dst_px));
   }
}

#endif /* DROID_CONVERT_H */
