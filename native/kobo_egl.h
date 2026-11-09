/* SPDX-License-Identifier: MIT */
#ifndef KOBO_EGL_H
#define KOBO_EGL_H
/* Per-process choice of EGL implementation.
 *
 * SurfaceFlinger composites with EGLImages made from gralloc buffers, which
 * only libGLES_android.so (software GLES 1.x) supports.  Every other process
 * gets the Mesa softpipe GLES2 implementation (libEGL_mesa.so and friends).
 * KitKat's libEGL Loader picks the implementation from properties, so the
 * preloaded shim answers those two property reads differently per process.
 *
 * Pure function so it can be tested on the host. Returns NULL when the real
 * property value must be used. */
const char *kobo_egl_override(const char *key, const char *process,
                              int caller_is_libegl, int mesa_installed,
                              int mesa_disabled);
#endif
