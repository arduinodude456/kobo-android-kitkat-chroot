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
#include <unistd.h>

static int base_is(const char *process, const char *name)
{
    const char *slash = strrchr(process, '/');
    return strcmp(slash ? slash + 1 : process, name) == 0;
}

const char *kobo_egl_override(const char *key, const char *process,
                              int caller_is_libegl, int mesa_installed,
                              int mesa_disabled)
{
    int use_mesa;

    if (!key || !process || !caller_is_libegl)
        return NULL;
    use_mesa = mesa_installed && !mesa_disabled &&
               !base_is(process, "surfaceflinger") &&
               !base_is(process, "bootanimation");
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
    static int have_process, installed = -1, disabled = -1;
    Dl_info info;
    int from_egl = 0;
    const char *forced;

    if (!have_process) {
        int fd = open("/proc/self/cmdline", O_RDONLY | O_CLOEXEC);
        ssize_t n = fd >= 0 ? read(fd, process, sizeof process - 1) : -1;
        if (fd >= 0) close(fd);
        process[n > 0 ? n : 0] = 0;
        have_process = 1;
    }
    if (installed < 0) {
        installed = access("/system/lib/egl/libEGL_mesa.so", R_OK) == 0;
        /* A file /data/local/kobo-gles-off turns the Mesa path off. */
        disabled = access("/data/local/kobo-gles-off", F_OK) == 0;
    }
    if (strncmp(key, "ro.hardware.egl", 16) == 0 || strncmp(key, "ro.kernel.qemu", 15) == 0) {
        if (dladdr(__builtin_return_address(0), &info) && info.dli_fname &&
            strstr(info.dli_fname, "libEGL"))
            from_egl = 1;
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
