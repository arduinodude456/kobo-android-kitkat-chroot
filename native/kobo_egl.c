/* SPDX-License-Identifier: MIT */
#define _GNU_SOURCE
#include "kobo_egl.h"
#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#if defined(__has_include)
#if __has_include(<sys/system_properties.h>)
#include <sys/system_properties.h>
#endif
#endif
#ifndef PROP_VALUE_MAX /* host builds (glibc) have no bionic property header */
#define PROP_VALUE_MAX 92
int __system_property_get(const char *name, char *value);
#endif
/* weak: absent on glibc hosts, where the tests link libkobofb.so directly */
extern int __system_property_get(const char *name, char *value) __attribute__((weak));
#include <sys/types.h>
#include <unistd.h>

static int has_prefix(const char *s, const char *prefix)
{
    return strncmp(s, prefix, strlen(prefix)) == 0;
}

/* Prozessnamen (Anfang von /proc/self/cmdline), die GLES2 ueber Mesa bekommen. */
static int process_wants_mesa(const char *process)
{
    static const char *const prefixes[] = {
        "org.mozilla.",        /* Firefox/Fennec, Focus */
        "com.android.chrome",  /* Chrome inkl. :sandboxed_process */
        "com.chrome.",
        "com.google.android.apps.chrome",
        "org.chromium.",
        NULL
    };
    int i;

    if (!process || !*process)
        return 0;
    for (i = 0; prefixes[i]; i++)
        if (has_prefix(process, prefixes[i]))
            return 1;
    return 0;
}

const char *kobo_egl_override(const char *key, const char *process,
                              int caller_is_libegl, int mesa_installed,
                              int mesa_disabled)
{
    int use_mesa;

    if (!key || !process || !caller_is_libegl)
        return NULL;
    /* Opt-in: nur Browser (Gecko/Chromium) brauchen GLES2. system_server, zygote,
     * SystemUI, Launcher usw. bleiben auf libGLES_android.so, sonst Bootschleife. */
    use_mesa = mesa_installed && !mesa_disabled && process_wants_mesa(process);
    if (strcmp(key, "ro.hardware.egl") == 0)
        return use_mesa ? "mesa" : NULL;
    /* qemu=1 makes the Loader pick libGLES_android.so unconditionally (or the
     * emulator libs); "0" restores the normal ro.hardware.egl tag lookup. */
    if (strcmp(key, "ro.kernel.qemu") == 0)
        return use_mesa ? "0" : NULL;
    return NULL;
}

/* Interposes libcutils' property_get() for libEGL.so only. */
int property_get(const char *key, char *value, const char *default_value)
{
    static char process[256];
    static int installed = -1, disabled = -1;
    Dl_info info;
    int from_egl = 0;
    const char *forced;

    if (installed < 0) {
        installed = access("/system/lib/egl/libEGL_mesa.so", R_OK) == 0;
        /* A file /data/local/kobo-gles-off turns the Mesa path off. */
        disabled = access("/data/local/kobo-gles-off", F_OK) == 0;
    }
    if (strncmp(key, "ro.hardware.egl", 16) == 0 || strncmp(key, "ro.kernel.qemu", 15) == 0) {
        if (dladdr(__builtin_return_address(0), &info) && info.dli_fname &&
            strstr(info.dli_fname, "libEGL")) {
            /* Prozessname bei JEDEM EGL-Aufruf frisch lesen (nur diese zwei Keys, selten):
             * Zygote-Forks heissen anfangs "zygote"; wuerde der Name bei irgendeinem frueheren
             * property_get() gecacht, bliebe er fuer immer "zygote" -> nie Mesa. */
            int fd = open("/proc/self/cmdline", O_RDONLY | O_CLOEXEC);
            ssize_t n = fd >= 0 ? read(fd, process, sizeof process - 1) : -1;
            if (fd >= 0) close(fd);
            process[n > 0 ? n : 0] = 0;
            from_egl = 1;
        }
    }
    forced = kobo_egl_override(key, process, from_egl, installed, disabled);
    if (forced) {
        strncpy(value, forced, PROP_VALUE_MAX - 1);
        value[PROP_VALUE_MAX - 1] = 0;
        return (int) strlen(value);
    }
    {
        int len = __system_property_get ? __system_property_get(key, value) : 0;
        if (len > 0)
            return len;
        if (default_value) {
            strncpy(value, default_value, PROP_VALUE_MAX - 1);
            value[PROP_VALUE_MAX - 1] = 0;
            return (int) strlen(value);
        }
        value[0] = 0;
        return 0;
    }
}
