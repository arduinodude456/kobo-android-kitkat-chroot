/* SPDX-License-Identifier: MIT */
#ifndef KOBO_EGL_H
#define KOBO_EGL_H
/* Per-process choice of EGL implementation.
 *
 * SurfaceFlinger composites with EGLImages made from gralloc buffers, which
 * only libGLES_android.so (software GLES 1.x) supports.  Every app process
 * (Chrome, Firefox, the stock browser/WebView, games, ...) gets the Mesa
 * softpipe GLES2 implementation (libEGL_mesa.so and friends).  KitKat's libEGL
 * Loader picks the implementation from properties, so the preloaded shim
 * answers those two property reads differently per process.
 *
 * Pure functions so they can be tested on the host. */

/* Does this process (first argument of /proc/self/cmdline) want Mesa?
 * all_apps != 0: every app process except the system ones (SurfaceFlinger,
 * bootanimation, zygote, system_server, SystemUI, launcher, keyguard, ...)
 * plus the on-device test binary.  all_apps == 0: only the known browsers
 * (legacy behaviour, switchable with KOBO_GLES_APPS=0). */
int kobo_egl_process_wants_mesa(const char *process, int all_apps);
/* 1, wenn /proc/cpuinfo-artige Datei NEON meldet (oder kein Features-Feld hat); 0 sonst. */
int kobo_cpu_has_neon(const char *cpuinfo_path);

/* Returns the forced property value, or NULL when the real value must be used.
 * mesa_usable: the Mesa libraries exist AND could be dlopen()ed in this process. */
const char *kobo_egl_override(const char *key, const char *process,
                              int caller_is_libegl, int mesa_usable,
                              int mesa_disabled, int all_apps);
#endif
