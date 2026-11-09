/*
 * SPDX-License-Identifier: MIT
 *
 * Software-only Android EGL platform for Mesa 18.0.x (kobo-android-kitkat-chroot).
 *
 * Mesa's stock platform_android.c needs a DRM render node and a DRM-aware
 * gralloc.  The Kobo Android chroot has neither: gralloc is the generic
 * software module (gralloc.default.so) and rendering is done on the CPU by
 * Mesa's softpipe through the "swrast" DRI driver.  This file replaces the
 * stock platform with a swrast/gralloc one:
 *
 *   eglCreateWindowSurface  -> remember the ANativeWindow, create a swrast drawable
 *   first draw of a frame   -> ANativeWindow::dequeueBuffer (lazily, from getDrawableInfo)
 *   eglSwapBuffers          -> softpipe presents through __DRIswrastLoaderExtension::putImage2,
 *                              we gralloc-lock the dequeued buffer, convert pixels, unlock,
 *                              and ANativeWindow::queueBuffer
 *
 * Only the ANativeWindow / gralloc interfaces of Android 4.4 (API 19) are used:
 * dequeueBuffer/queueBuffer/cancelBuffer with fence fds, gralloc lock/unlock.
 * The framework libEGL (frameworks/native) connects the window to
 * NATIVE_WINDOW_API_EGL and sets the buffer format before it calls us.
 *
 * Not provided (the software gralloc cannot share buffers with Mesa):
 * EGL_ANDROID_image_native_buffer / EGLImage from ANativeWindowBuffer.
 * SurfaceFlinger therefore keeps using libGLES_android.so; only application
 * processes load this implementation (see native/kobo_egl.c).
 */

#include <errno.h>
#include <dlfcn.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <sync/sync.h>

#include "loader.h"
#include "egl_dri2.h"
#include "egl_dri2_fallbacks.h"

/* Pixel layouts we can produce or consume, named by the byte order in memory. */
enum droid_px {
   DROID_PX_NONE = 0,
   DROID_PX_RGBA,   /* HAL_PIXEL_FORMAT_RGBA_8888: bytes R,G,B,A */
   DROID_PX_RGBX,   /* HAL_PIXEL_FORMAT_RGBX_8888: bytes R,G,B,x */
   DROID_PX_BGRA,   /* HAL_PIXEL_FORMAT_BGRA_8888 / Mesa B8G8R8A8: bytes B,G,R,A */
   DROID_PX_BGRX,   /* Mesa B8G8R8X8: bytes B,G,R,x */
   DROID_PX_565,    /* HAL_PIXEL_FORMAT_RGB_565 / Mesa B5G6R5: little endian 16 bit */
};

static int
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

static enum droid_px
droid_px_from_hal(int format)
{
   switch (format) {
   case HAL_PIXEL_FORMAT_RGBA_8888: return DROID_PX_RGBA;
   case HAL_PIXEL_FORMAT_RGBX_8888: return DROID_PX_RGBX;
   case HAL_PIXEL_FORMAT_BGRA_8888: return DROID_PX_BGRA;
   case HAL_PIXEL_FORMAT_RGB_565:   return DROID_PX_565;
   default:                         return DROID_PX_NONE;
   }
}

/* Layout of the pixels softpipe hands to putImage2 for this EGLConfig. */
static enum droid_px
droid_px_from_config(const _EGLConfig *conf)
{
   if (conf->RedSize == 5)
      return DROID_PX_565;
   return conf->AlphaSize > 0 ? DROID_PX_BGRA : DROID_PX_BGRX;
}

static inline bool
droid_px_has_alpha(enum droid_px px)
{
   return px == DROID_PX_RGBA || px == DROID_PX_BGRA;
}

static void
droid_decode(enum droid_px px, const uint8_t *s, unsigned *r, unsigned *g,
             unsigned *b, unsigned *a)
{
   switch (px) {
   case DROID_PX_RGBA: *r = s[0]; *g = s[1]; *b = s[2]; *a = s[3]; break;
   case DROID_PX_RGBX: *r = s[0]; *g = s[1]; *b = s[2]; *a = 0xff; break;
   case DROID_PX_BGRA: *b = s[0]; *g = s[1]; *r = s[2]; *a = s[3]; break;
   case DROID_PX_BGRX: *b = s[0]; *g = s[1]; *r = s[2]; *a = 0xff; break;
   case DROID_PX_565: {
      unsigned p = s[0] | (s[1] << 8);
      unsigned rr = (p >> 11) & 0x1f, gg = (p >> 5) & 0x3f, bb = p & 0x1f;
      *r = (rr << 3) | (rr >> 2);
      *g = (gg << 2) | (gg >> 4);
      *b = (bb << 3) | (bb >> 2);
      *a = 0xff;
      break;
   }
   default: *r = *g = *b = 0; *a = 0xff; break;
   }
}

static void
droid_encode(enum droid_px px, uint8_t *d, unsigned r, unsigned g, unsigned b,
             unsigned a)
{
   switch (px) {
   case DROID_PX_RGBA: d[0] = r; d[1] = g; d[2] = b; d[3] = a; break;
   case DROID_PX_RGBX: d[0] = r; d[1] = g; d[2] = b; d[3] = 0xff; break;
   case DROID_PX_BGRA: d[0] = b; d[1] = g; d[2] = r; d[3] = a; break;
   case DROID_PX_BGRX: d[0] = b; d[1] = g; d[2] = r; d[3] = 0xff; break;
   case DROID_PX_565: {
      unsigned p = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
      d[0] = p & 0xff;
      d[1] = p >> 8;
      break;
   }
   default: break;
   }
}

/* Convert one row of n pixels.  X formats have an undefined alpha byte: it is
 * forced to 0xff whenever either side has no alpha. */
static void
droid_convert_row(enum droid_px dst_px, uint8_t *dst,
                  enum droid_px src_px, const uint8_t *src, int n)
{
   int i;

   if (dst_px == src_px) {
      memcpy(dst, src, (size_t) n * droid_px_bytes(src_px));
      return;
   }

   /* Fast path: R<->B swizzle between 32 bit layouts with the same alpha kind. */
   if (droid_px_bytes(src_px) == 4 && droid_px_bytes(dst_px) == 4) {
      bool swap = ((src_px == DROID_PX_BGRA || src_px == DROID_PX_BGRX) !=
                   (dst_px == DROID_PX_BGRA || dst_px == DROID_PX_BGRX));
      bool force_opaque = !droid_px_has_alpha(src_px) || !droid_px_has_alpha(dst_px);
      for (i = 0; i < n; i++, src += 4, dst += 4) {
         uint8_t c0 = src[0], c1 = src[1], c2 = src[2], c3 = src[3];
         if (swap) {
            uint8_t t = c0; c0 = c2; c2 = t;
         }
         dst[0] = c0;
         dst[1] = c1;
         dst[2] = c2;
         dst[3] = force_opaque ? 0xff : c3;
      }
      return;
   }

   {
      const int sb = droid_px_bytes(src_px), db = droid_px_bytes(dst_px);
      for (i = 0; i < n; i++, src += sb, dst += db) {
         unsigned r, g, b, a;
         droid_decode(src_px, src, &r, &g, &b, &a);
         droid_encode(dst_px, dst, r, g, b, a);
      }
   }
}

/* ---------------------------------------------------------------------- */

static int
droid_usage(void)
{
   return GRALLOC_USAGE_SW_READ_OFTEN | GRALLOC_USAGE_SW_WRITE_OFTEN;
}

static EGLBoolean
droid_window_dequeue_buffer(struct dri2_egl_surface *dri2_surf)
{
   int fence_fd = -1;

   if (dri2_surf->buffer)
      return EGL_TRUE;

   if (dri2_surf->window->dequeueBuffer(dri2_surf->window, &dri2_surf->buffer,
                                        &fence_fd) || !dri2_surf->buffer) {
      dri2_surf->buffer = NULL;
      return EGL_FALSE;
   }

   /* The producer may not touch the buffer before this fence signals.
    * From ANativeWindow::dequeueBuffer: -1 means "access immediately"; a valid
    * descriptor must be closed by us. */
   if (fence_fd >= 0) {
      sync_wait(fence_fd, -1);
      close(fence_fd);
   }

   dri2_surf->buffer->common.incRef(&dri2_surf->buffer->common);
   dri2_surf->base.Width = dri2_surf->buffer->width;
   dri2_surf->base.Height = dri2_surf->buffer->height;
   return EGL_TRUE;
}

static void
droid_window_cancel_buffer(struct dri2_egl_surface *dri2_surf)
{
   if (!dri2_surf->buffer)
      return;

   if (dri2_surf->window->cancelBuffer(dri2_surf->window, dri2_surf->buffer, -1) < 0) {
      _eglLog(_EGL_WARNING, "ANativeWindow::cancelBuffer failed");
      dri2_surf->base.Lost = EGL_TRUE;
   }
   dri2_surf->buffer->common.decRef(&dri2_surf->buffer->common);
   dri2_surf->buffer = NULL;
}

static EGLBoolean
droid_window_enqueue_buffer(_EGLDisplay *disp, struct dri2_egl_surface *dri2_surf)
{
   /* Do not hold the display mutex while SurfaceFlinger may block us. */
   mtx_unlock(&disp->Mutex);
   dri2_surf->window->queueBuffer(dri2_surf->window, dri2_surf->buffer, -1);
   dri2_surf->buffer->common.decRef(&dri2_surf->buffer->common);
   dri2_surf->buffer = NULL;
   mtx_lock(&disp->Mutex);
   return EGL_TRUE;
}

/* ---------------------------------------------------------------------- */
/* __DRIswrastLoaderExtension                                              */

static void
droid_swrast_get_drawable_info(__DRIdrawable *draw, int *x, int *y, int *w,
                               int *h, void *loaderPrivate)
{
   struct dri2_egl_surface *dri2_surf = loaderPrivate;

   if (dri2_surf->base.Type == EGL_WINDOW_BIT && dri2_surf->window) {
      if (!droid_window_dequeue_buffer(dri2_surf)) {
         int width = dri2_surf->base.Width, height = dri2_surf->base.Height;
         dri2_surf->window->query(dri2_surf->window, NATIVE_WINDOW_DEFAULT_WIDTH, &width);
         dri2_surf->window->query(dri2_surf->window, NATIVE_WINDOW_DEFAULT_HEIGHT, &height);
         dri2_surf->base.Width = width;
         dri2_surf->base.Height = height;
      }
   }

   *x = 0;
   *y = 0;
   *w = dri2_surf->base.Width;
   *h = dri2_surf->base.Height;
}

/* Lock the current window buffer.  Returns the base address or NULL. */
static uint8_t *
droid_lock_buffer(struct dri2_egl_surface *dri2_surf, int *stride_bytes,
                  enum droid_px *px)
{
   struct dri2_egl_display *dri2_dpy =
      dri2_egl_display(dri2_surf->base.Resource.Display);
   struct ANativeWindowBuffer *buf = dri2_surf->buffer;
   void *vaddr = NULL;

   if (!buf)
      return NULL;

   *px = droid_px_from_hal(buf->format);
   if (*px == DROID_PX_NONE) {
      _eglLog(_EGL_WARNING, "unsupported window buffer format 0x%x", buf->format);
      return NULL;
   }

   if (dri2_dpy->gralloc->lock(dri2_dpy->gralloc, buf->handle, droid_usage(),
                               0, 0, buf->width, buf->height, &vaddr) || !vaddr) {
      _eglLog(_EGL_WARNING, "gralloc lock failed");
      return NULL;
   }

   *stride_bytes = buf->stride * droid_px_bytes(*px);
   return vaddr;
}

static void
droid_unlock_buffer(struct dri2_egl_surface *dri2_surf)
{
   struct dri2_egl_display *dri2_dpy =
      dri2_egl_display(dri2_surf->base.Resource.Display);

   dri2_dpy->gralloc->unlock(dri2_dpy->gralloc, dri2_surf->buffer->handle);
}

static void
droid_swrast_put_image2(__DRIdrawable *draw, int op, int x, int y, int w, int h,
                        int stride, char *data, void *loaderPrivate)
{
   struct dri2_egl_surface *dri2_surf = loaderPrivate;
   const enum droid_px src_px = droid_px_from_config(dri2_surf->base.Config);
   enum droid_px dst_px;
   int dst_stride;
   uint8_t *dst;
   const uint8_t *src = (const uint8_t *) data;

   if (dri2_surf->base.Type != EGL_WINDOW_BIT || !dri2_surf->window)
      return;
   if (!droid_window_dequeue_buffer(dri2_surf))
      return;

   dst = droid_lock_buffer(dri2_surf, &dst_stride, &dst_px);
   if (!dst)
      return;

   /* Clip to the dequeued buffer; drivers expect the loader to do this. */
   if (x < 0 || y < 0) {
      droid_unlock_buffer(dri2_surf);
      return;
   }
   if (x + w > dri2_surf->buffer->width)
      w = dri2_surf->buffer->width - x;
   if (y + h > dri2_surf->buffer->height)
      h = dri2_surf->buffer->height - y;

   if (w > 0) {
      dst += (size_t) y * dst_stride + (size_t) x * droid_px_bytes(dst_px);
      for (; h > 0; h--) {
         droid_convert_row(dst_px, dst, src_px, src, w);
         src += stride;
         dst += dst_stride;
      }
   }

   droid_unlock_buffer(dri2_surf);
}

static void
droid_swrast_put_image(__DRIdrawable *draw, int op, int x, int y, int w, int h,
                       char *data, void *loaderPrivate)
{
   struct dri2_egl_surface *dri2_surf = loaderPrivate;
   const enum droid_px src_px = droid_px_from_config(dri2_surf->base.Config);

   droid_swrast_put_image2(draw, op, x, y, w, h,
                           w * droid_px_bytes(src_px), data, loaderPrivate);
}

static void
droid_swrast_get_image(__DRIdrawable *read, int x, int y, int w, int h,
                       char *data, void *loaderPrivate)
{
   struct dri2_egl_surface *dri2_surf = loaderPrivate;
   const enum droid_px dst_px = droid_px_from_config(dri2_surf->base.Config);
   const int dst_stride = w * droid_px_bytes(dst_px);
   enum droid_px src_px;
   int src_stride;
   const uint8_t *src;
   uint8_t *dst = (uint8_t *) data;

   /* Nothing readable (pbuffer, or no buffer dequeued yet): return black. */
   src = (dri2_surf->base.Type == EGL_WINDOW_BIT && dri2_surf->buffer) ?
      droid_lock_buffer(dri2_surf, &src_stride, &src_px) : NULL;
   if (!src || x < 0 || y < 0 ||
       x + w > dri2_surf->buffer->width || y + h > dri2_surf->buffer->height) {
      memset(data, 0, (size_t) dst_stride * (h > 0 ? h : 0));
      if (src)
         droid_unlock_buffer(dri2_surf);
      return;
   }

   src += (size_t) y * src_stride + (size_t) x * droid_px_bytes(src_px);
   for (; h > 0; h--) {
      droid_convert_row(dst_px, dst, src_px, src, w);
      src += src_stride;
      dst += dst_stride;
   }
   droid_unlock_buffer(dri2_surf);
}

/* ---------------------------------------------------------------------- */
/* Surfaces                                                                */

static _EGLSurface *
droid_create_surface(_EGLDriver *drv, _EGLDisplay *disp, EGLint type,
                     _EGLConfig *conf, void *native_window,
                     const EGLint *attrib_list)
{
   struct dri2_egl_display *dri2_dpy = dri2_egl_display(disp);
   struct dri2_egl_config *dri2_conf = dri2_egl_config(conf);
   struct dri2_egl_surface *dri2_surf;
   struct ANativeWindow *window = native_window;
   const __DRIconfig *config;

   dri2_surf = calloc(1, sizeof *dri2_surf);
   if (!dri2_surf) {
      _eglError(EGL_BAD_ALLOC, "droid_create_surface");
      return NULL;
   }

   if (!dri2_init_surface(&dri2_surf->base, disp, type, conf, attrib_list, false))
      goto cleanup_surface;

   if (type == EGL_WINDOW_BIT) {
      int format;

      if (!window || window->common.magic != ANDROID_NATIVE_WINDOW_MAGIC) {
         _eglError(EGL_BAD_NATIVE_WINDOW, "droid_create_surface");
         goto cleanup_surface;
      }
      if (window->query(window, NATIVE_WINDOW_FORMAT, &format)) {
         _eglError(EGL_BAD_NATIVE_WINDOW, "droid_create_surface");
         goto cleanup_surface;
      }
      if (format != dri2_conf->base.NativeVisualID)
         _eglLog(_EGL_DEBUG, "Native format mismatch: 0x%x != 0x%x (converting)",
                 format, dri2_conf->base.NativeVisualID);

      /* We write the buffers with the CPU and may read them back. */
      window->perform(window, NATIVE_WINDOW_SET_USAGE, droid_usage());

      window->query(window, NATIVE_WINDOW_DEFAULT_WIDTH, &dri2_surf->base.Width);
      window->query(window, NATIVE_WINDOW_DEFAULT_HEIGHT, &dri2_surf->base.Height);
   }

   config = dri2_get_dri_config(dri2_conf, type, dri2_surf->base.GLColorspace);
   if (!config)
      goto cleanup_surface;

   dri2_surf->dri_drawable =
      dri2_dpy->swrast->createNewDrawable(dri2_dpy->dri_screen, config, dri2_surf);
   if (dri2_surf->dri_drawable == NULL) {
      _eglError(EGL_BAD_ALLOC, "swrast createNewDrawable");
      goto cleanup_surface;
   }

   if (window) {
      window->common.incRef(&window->common);
      dri2_surf->window = window;
   }

   return &dri2_surf->base;

cleanup_surface:
   free(dri2_surf);
   return NULL;
}

static _EGLSurface *
droid_create_window_surface(_EGLDriver *drv, _EGLDisplay *disp,
                            _EGLConfig *conf, void *native_window,
                            const EGLint *attrib_list)
{
   return droid_create_surface(drv, disp, EGL_WINDOW_BIT, conf, native_window,
                               attrib_list);
}

static _EGLSurface *
droid_create_pbuffer_surface(_EGLDriver *drv, _EGLDisplay *disp,
                             _EGLConfig *conf, const EGLint *attrib_list)
{
   return droid_create_surface(drv, disp, EGL_PBUFFER_BIT, conf, NULL,
                               attrib_list);
}

static EGLBoolean
droid_destroy_surface(_EGLDriver *drv, _EGLDisplay *disp, _EGLSurface *surf)
{
   struct dri2_egl_display *dri2_dpy = dri2_egl_display(disp);
   struct dri2_egl_surface *dri2_surf = dri2_egl_surface(surf);

   if (dri2_surf->base.Type == EGL_WINDOW_BIT && dri2_surf->window) {
      droid_window_cancel_buffer(dri2_surf);
      dri2_surf->window->common.decRef(&dri2_surf->window->common);
   }

   dri2_dpy->core->destroyDrawable(dri2_surf->dri_drawable);

   dri2_fini_surface(surf);
   free(dri2_surf);

   return EGL_TRUE;
}

static EGLBoolean
droid_swap_buffers(_EGLDriver *drv, _EGLDisplay *disp, _EGLSurface *draw)
{
   struct dri2_egl_display *dri2_dpy = dri2_egl_display(disp);
   struct dri2_egl_surface *dri2_surf = dri2_egl_surface(draw);

   if (dri2_surf->base.Type != EGL_WINDOW_BIT)
      return EGL_TRUE;

   /* softpipe flushes and presents through putImage2 (dequeue, lock, convert,
    * unlock). */
   dri2_dpy->core->swapBuffers(dri2_surf->dri_drawable);

   /* The buffer is NULL when nothing was rendered since the last swap. */
   if (dri2_surf->buffer)
      droid_window_enqueue_buffer(disp, dri2_surf);

   /* softpipe marks the drawable stale after every present (drisw.c), so the
    * next frame calls getDrawableInfo again and picks up a new buffer size. */

   return EGL_TRUE;
}

static EGLBoolean
droid_query_surface(_EGLDriver *drv, _EGLDisplay *dpy, _EGLSurface *surf,
                    EGLint attribute, EGLint *value)
{
   struct dri2_egl_surface *dri2_surf = dri2_egl_surface(surf);

   if (dri2_surf->base.Type == EGL_WINDOW_BIT && dri2_surf->window) {
      switch (attribute) {
      case EGL_WIDTH:
         dri2_surf->window->query(dri2_surf->window,
                                  NATIVE_WINDOW_DEFAULT_WIDTH, value);
         return EGL_TRUE;
      case EGL_HEIGHT:
         dri2_surf->window->query(dri2_surf->window,
                                  NATIVE_WINDOW_DEFAULT_HEIGHT, value);
         return EGL_TRUE;
      default:
         break;
      }
   }
   return _eglQuerySurface(drv, dpy, surf, attribute, value);
}

/* ---------------------------------------------------------------------- */
/* Configs                                                                 */

static EGLBoolean
droid_add_configs_for_visuals(_EGLDriver *drv, _EGLDisplay *dpy)
{
   struct dri2_egl_display *dri2_dpy = dri2_egl_display(dpy);
   /* rgba_masks describe the DRI (softpipe) drawable, which is B,G,R,A in
    * memory for the 32 bit formats; NativeVisualID is the gralloc format the
    * window will use and putImage2 converts between the two. */
   static const struct {
      int format;
      unsigned int rgba_masks[4];
   } visuals[] = {
      { HAL_PIXEL_FORMAT_RGBA_8888, { 0x00ff0000, 0x0000ff00, 0x000000ff, 0xff000000 } },
      { HAL_PIXEL_FORMAT_RGBX_8888, { 0x00ff0000, 0x0000ff00, 0x000000ff, 0x00000000 } },
      { HAL_PIXEL_FORMAT_RGB_565,   { 0x0000f800, 0x000007e0, 0x0000001f, 0x00000000 } },
      { HAL_PIXEL_FORMAT_BGRA_8888, { 0x00ff0000, 0x0000ff00, 0x000000ff, 0xff000000 } },
   };
   unsigned int format_count[ARRAY_SIZE(visuals)] = { 0 };
   int config_count = 0;

   /* All configs of HAL format i precede those of format i+1: many clients
    * pick the first config whose channel sizes match and ignore the visual id. */
   for (int i = 0; i < ARRAY_SIZE(visuals); i++) {
      for (int j = 0; dri2_dpy->driver_configs[j]; j++) {
         const EGLint config_attrs[] = {
            EGL_NATIVE_VISUAL_ID,   visuals[i].format,
            EGL_NATIVE_VISUAL_TYPE, visuals[i].format,
            EGL_RECORDABLE_ANDROID, EGL_TRUE,
            EGL_NONE
         };
         struct dri2_egl_config *dri2_conf =
            dri2_add_config(dpy, dri2_dpy->driver_configs[j], config_count + 1,
                            EGL_WINDOW_BIT | EGL_PBUFFER_BIT, config_attrs,
                            visuals[i].rgba_masks);
         if (dri2_conf) {
            if (dri2_conf->base.ConfigID == config_count + 1)
               config_count++;
            format_count[i]++;
         }
      }
   }

   for (int i = 0; i < ARRAY_SIZE(format_count); i++) {
      if (!format_count[i])
         _eglLog(_EGL_DEBUG, "No swrast config supports native format 0x%x",
                 visuals[i].format);
   }

   return config_count != 0;
}

/* ---------------------------------------------------------------------- */

static const struct dri2_egl_display_vtbl droid_display_vtbl = {
   .authenticate = NULL,
   .create_window_surface = droid_create_window_surface,
   .create_pixmap_surface = dri2_fallback_create_pixmap_surface,
   .create_pbuffer_surface = droid_create_pbuffer_surface,
   .destroy_surface = droid_destroy_surface,
   .create_image = dri2_fallback_create_image_khr,
   .swap_buffers = droid_swap_buffers,
   .swap_buffers_with_damage = dri2_fallback_swap_buffers_with_damage,
   .swap_buffers_region = dri2_fallback_swap_buffers_region,
   .set_damage_region = dri2_fallback_set_damage_region,
   .post_sub_buffer = dri2_fallback_post_sub_buffer,
   .copy_buffers = dri2_fallback_copy_buffers,
   .query_buffer_age = dri2_fallback_query_buffer_age,
   .query_surface = droid_query_surface,
   .create_wayland_buffer_from_image = dri2_fallback_create_wayland_buffer_from_image,
   .get_sync_values = dri2_fallback_get_sync_values,
   .get_dri_drawable = dri2_surface_get_dri_drawable,
};

static const __DRIswrastLoaderExtension droid_swrast_loader_extension = {
   .base = { __DRI_SWRAST_LOADER, 2 },

   .getDrawableInfo = droid_swrast_get_drawable_info,
   .putImage        = droid_swrast_put_image,
   .getImage        = droid_swrast_get_image,
   .putImage2       = droid_swrast_put_image2,
};

static const __DRIextension *droid_swrast_loader_extensions[] = {
   &droid_swrast_loader_extension.base,
   &image_lookup_extension.base,
   &use_invalidate.base,
   NULL,
};

EGLBoolean
dri2_initialize_android(_EGLDriver *drv, _EGLDisplay *disp)
{
   struct dri2_egl_display *dri2_dpy;
   const char *err;
   int ret;

   loader_set_logger(_eglLog);

   dri2_dpy = calloc(1, sizeof(*dri2_dpy));
   if (!dri2_dpy)
      return _eglError(EGL_BAD_ALLOC, "eglInitialize");

   dri2_dpy->fd = -1;
   disp->DriverData = (void *) dri2_dpy;

   ret = hw_get_module(GRALLOC_HARDWARE_MODULE_ID,
                       (const hw_module_t **) &dri2_dpy->gralloc);
   if (ret || !dri2_dpy->gralloc || !dri2_dpy->gralloc->lock ||
       !dri2_dpy->gralloc->unlock) {
      err = "swrast: failed to get gralloc module";
      goto cleanup;
   }

   dri2_dpy->driver_name = strdup("swrast");
   if (!dri2_dpy->driver_name || !dri2_load_driver_swrast(disp)) {
      err = "swrast: failed to load swrast_dri.so";
      goto cleanup;
   }

   dri2_dpy->loader_extensions = droid_swrast_loader_extensions;

   if (!dri2_create_screen(disp)) {
      err = "swrast: failed to create screen";
      goto cleanup;
   }

   if (!dri2_setup_extensions(disp)) {
      err = "swrast: failed to setup extensions";
      goto cleanup;
   }

   dri2_setup_screen(disp);

   if (!droid_add_configs_for_visuals(drv, disp)) {
      err = "swrast: failed to add configs";
      goto cleanup;
   }

   disp->Extensions.ANDROID_recordable = EGL_TRUE;

   /* Fill vtbl last to prevent accidentally calling virtual function during
    * initialization. */
   dri2_dpy->vtbl = &droid_display_vtbl;

   return EGL_TRUE;

cleanup:
   dri2_display_destroy(disp);
   return _eglError(EGL_NOT_INITIALIZED, err);
}
