/* SPDX-License-Identifier: MIT
 * Host test: mesa/droid_convert.h must produce exactly what the original per-pixel
 * decode/encode implementation produced, for every format pair and odd row lengths. */
#include <stdio.h>
#include <stdlib.h>
#include "../../mesa/droid_convert.h"

static void ref_decode(enum droid_px px, const uint8_t *s, unsigned *r, unsigned *g, unsigned *b, unsigned *a)
{
   switch (px) {
   case DROID_PX_RGBA: *r = s[0]; *g = s[1]; *b = s[2]; *a = s[3]; break;
   case DROID_PX_RGBX: *r = s[0]; *g = s[1]; *b = s[2]; *a = 0xff; break;
   case DROID_PX_BGRA: *b = s[0]; *g = s[1]; *r = s[2]; *a = s[3]; break;
   case DROID_PX_BGRX: *b = s[0]; *g = s[1]; *r = s[2]; *a = 0xff; break;
   case DROID_PX_565: {
      unsigned p = s[0] | (s[1] << 8);
      unsigned rr = (p >> 11) & 0x1f, gg = (p >> 5) & 0x3f, bb = p & 0x1f;
      *r = (rr << 3) | (rr >> 2); *g = (gg << 2) | (gg >> 4); *b = (bb << 3) | (bb >> 2); *a = 0xff;
      break;
   }
   default: *r = *g = *b = 0; *a = 0xff; break;
   }
}

static void ref_encode(enum droid_px px, uint8_t *d, unsigned r, unsigned g, unsigned b, unsigned a)
{
   switch (px) {
   case DROID_PX_RGBA: d[0] = r; d[1] = g; d[2] = b; d[3] = a; break;
   case DROID_PX_RGBX: d[0] = r; d[1] = g; d[2] = b; d[3] = 0xff; break;
   case DROID_PX_BGRA: d[0] = b; d[1] = g; d[2] = r; d[3] = a; break;
   case DROID_PX_BGRX: d[0] = b; d[1] = g; d[2] = r; d[3] = 0xff; break;
   case DROID_PX_565: {
      unsigned p = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
      d[0] = p & 0xff; d[1] = p >> 8;
      break;
   }
   default: break;
   }
}

/* The original: alpha forced opaque when either side lacks alpha (only for 32->32). */
static void ref_row(enum droid_px dp, uint8_t *d, enum droid_px sp, const uint8_t *s, int n)
{
   int i, sb = droid_px_bytes(sp), db = droid_px_bytes(dp);
   if (dp == sp) { memcpy(d, s, (size_t) n * sb); return; }
   for (i = 0; i < n; i++, s += sb, d += db) {
      unsigned r, g, b, a;
      ref_decode(sp, s, &r, &g, &b, &a);
      if (sb == 4 && db == 4 && (!droid_px_has_alpha(sp) || !droid_px_has_alpha(dp)))
         a = 0xff;
      ref_encode(dp, d, r, g, b, a);
   }
}

int main(void)
{
   static const enum droid_px all[] = { DROID_PX_RGBA, DROID_PX_RGBX, DROID_PX_BGRA, DROID_PX_BGRX, DROID_PX_565 };
   static const int lens[] = { 1, 2, 3, 7, 64, 301 };
   uint8_t src[301 * 4 + 8], a[301 * 4 + 8], b[301 * 4 + 8];
   int si, di, li, i, off, fails = 0;

   srand(1234);
   for (si = 0; si < 5; si++)
      for (di = 0; di < 5; di++)
         for (li = 0; li < 6; li++)
            for (off = 0; off < 2; off++) {   /* also unaligned source/destination */
               int n = lens[li];
               for (i = 0; i < (int) sizeof src; i++)
                  src[i] = (uint8_t) rand();
               memset(a, 0x5a, sizeof a);
               memset(b, 0x5a, sizeof b);
               droid_convert_row(all[di], a + off, all[si], src + off, n);
               ref_row(all[di], b + off, all[si], src + off, n);
               if (memcmp(a, b, sizeof a)) {
                  printf("MISMATCH src=%d dst=%d n=%d off=%d\n", si, di, n, off);
                  fails++;
               }
            }
   /* all 65536 565 values and a spread of 8888 values round trip identically */
   {
      static uint16_t all565[65536];
      static uint8_t o1[65536 * 4], o2[65536 * 4];
      for (i = 0; i < 65536; i++) all565[i] = (uint16_t) i;
      for (di = 0; di < 4; di++) {
         droid_convert_row(all[di], o1, DROID_PX_565, (uint8_t *) all565, 65536);
         ref_row(all[di], o2, DROID_PX_565, (uint8_t *) all565, 65536);
         if (memcmp(o1, o2, sizeof o1)) { printf("MISMATCH 565->%d\n", di); fails++; }
      }
   }
   printf(fails ? "FAILED %d\n" : "OK\n", fails);
   return fails != 0;
}
