/* SPDX-License-Identifier: MIT */
#define _GNU_SOURCE
#include "kobo_egl.h"
#include "kobo_log.h"
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
/* implemented in kobo_log.c (same library); weak so host unit tests still link */
extern int __android_log_print(int prio, const char *tag, const char *fmt, ...) __attribute__((weak));
#include <sys/types.h>
#include <unistd.h>
#include <signal.h>
#include <stdlib.h>
#if defined(__arm__)
#include <ucontext.h>
#endif

#define KOBO_EGL_TAG "kobo-egl"
#define LOG_INFO  4
#define LOG_ERROR 6

static int has_prefix(const char *s, const char *prefix)
{
    return strncmp(s, prefix, strlen(prefix)) == 0;
}

static const char *base_name(const char *s)
{
    const char *slash = strrchr(s, '/');
    return slash ? slash + 1 : s;
}

/* Processes that must keep libGLES_android.so (EGLImage/gralloc, or boot-critical). */
static int is_system_process(const char *process)
{
    static const char *const exact[] = {
        "zygote", "system_server", "<pre-initialized>", "app_process",
        "surfaceflinger", "bootanimation", "mediaserver", "installd", "servicemanager",
        NULL
    };
    static const char *const prefixes[] = {
        "com.android.systemui",   /* also hosts ImageWallpaper */
        "com.android.launcher",
        "com.android.keyguard",
        "com.android.inputmethod",
        "com.android.phone",
        NULL
    };
    int i;

    for (i = 0; exact[i]; i++)
        if (strcmp(process, exact[i]) == 0 || strcmp(base_name(process), exact[i]) == 0)
            return 1;
    for (i = 0; prefixes[i]; i++)
        if (has_prefix(process, prefixes[i]))
            return 1;
    return 0;
}

int kobo_egl_process_wants_mesa(const char *process, int all_apps)
{
    static const char *const browsers[] = {
        "org.mozilla.",        /* Firefox/Fennec, Focus */
        "com.android.chrome",  /* Chrome inkl. :privileged_process0 (GPU) und :sandboxed_process */
        "com.chrome.",
        "com.google.android.apps.chrome",
        "org.chromium.",
        "com.android.browser", /* Stock browser: WebView/Chromium needs GLES2 */
        "com.google.android.webview",
        NULL
    };
    int i;

    if (!process || !*process)
        return 0;
    for (i = 0; browsers[i]; i++)
        if (has_prefix(process, browsers[i]))
            return 1;
    /* On-device smoke test (sh android.sh gles-test) */
    if (strcmp(base_name(process), "kobo-gles-test") == 0)
        return 1;
    if (!all_apps)
        return 0;
    /* Native daemons/tools are started by absolute path; app processes are package names. */
    if (process[0] == '/' || strchr(process, '/'))
        return 0;
    return !is_system_process(process);
}

const char *kobo_egl_override(const char *key, const char *process,
                              int caller_is_libegl, int mesa_usable,
                              int mesa_disabled, int all_apps)
{
    int use_mesa;

    if (!key || !process || !caller_is_libegl)
        return NULL;
    use_mesa = mesa_usable && !mesa_disabled && kobo_egl_process_wants_mesa(process, all_apps);
    if (strcmp(key, "ro.hardware.egl") == 0)
        return use_mesa ? "mesa" : NULL;
    /* qemu=1 makes the Loader pick libGLES_android.so unconditionally (or the
     * emulator libs); "0" restores the normal ro.hardware.egl tag lookup. */
    if (strcmp(key, "ro.kernel.qemu") == 0)
        return use_mesa ? "0" : NULL;
    return NULL;
}

/* Mesa-Prozesse (llvmpipe-JIT) sterben sonst ohne jede Spur: LLVM beendet sich bei Fehlern per exit(1),
 * und debuggerd liefert hier keine Tombstones.  Deshalb loggt der Shim (Tag kobo-egl) jeden exit() und
 * jedes harte Signal samt Absturzadresse (Bibliothek + Offset aus /proc/self/maps). */
static char crash_process[128];
static struct sigaction crash_old[32];

static void describe_addr(char *out, size_t n, unsigned long a)
{
    FILE *f = fopen("/proc/self/maps", "r");
    char line[512];

    snprintf(out, n, "0x%lx (nicht in maps)", a);
    if (!f)
        return;
    while (fgets(line, sizeof line, f)) {
        unsigned long lo, hi, off;
        char perms[8] = "", path[320] = "";
        if (sscanf(line, "%lx-%lx %7s %lx %*s %*s %319[^\n]", &lo, &hi, perms, &off, path) >= 4 &&
            a >= lo && a < hi) {
            const char *name = path[0] ? base_name(path) : "[anonym, JIT-Code?]";
            snprintf(out, n, "0x%lx = %s+0x%lx (%s)", a, name, a - lo + off, perms);
            break;
        }
    }
    fclose(f);
}

static void crash_handler(int sig, siginfo_t *si, void *ctx)
{
    char where[400], pcs[400], lrs[400];
    unsigned long pc = 0, lr = 0;

    (void) ctx;
#if defined(__arm__)
    pc = ((ucontext_t *) ctx)->uc_mcontext.arm_pc;
    lr = ((ucontext_t *) ctx)->uc_mcontext.arm_lr;
#endif
    describe_addr(where, sizeof where, (unsigned long) (si ? si->si_addr : 0));
    describe_addr(pcs, sizeof pcs, pc);
    describe_addr(lrs, sizeof lrs, lr);
    if (__android_log_print)
        __android_log_print(LOG_ERROR, KOBO_EGL_TAG, "%s: Signal %d code=%d Fehleradresse %s | pc %s | lr %s",
                            crash_process, sig, si ? si->si_code : 0, where, pcs, lrs);
    sigaction(sig, &crash_old[sig], NULL);   /* danach greift wieder der alte Handler (debuggerd) */
}

static void exit_note(void)
{
    if (__android_log_print)
        __android_log_print(LOG_ERROR, KOBO_EGL_TAG, "%s: Prozess beendet sich per exit()", crash_process);
}

static void install_crash_reporter(const char *process)
{
    static int done;
    static const int sigs[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT };
    struct sigaction sa;
    unsigned i;

    if (done)
        return;
    done = 1;
    snprintf(crash_process, sizeof crash_process, "%.120s", process);
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = crash_handler;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    for (i = 0; i < sizeof sigs / sizeof sigs[0]; i++)
        sigaction(sigs[i], &sa, &crash_old[sigs[i]]);
    atexit(exit_note);
}

/* KitKat's Loader treats a failed dlopen() of the chosen driver as fatal
 * (LOG_ALWAYS_FATAL "couldn't find an OpenGL ES implementation" -> SIGABRT, which in turn makes
 * Chrome print "GPU process isn't usable. Goodbye." and crash).  So dlopen() the Mesa libraries
 * ourselves first: log the linker's real error message, and fall back to libGLES_android.so
 * when Mesa cannot be loaded.  The handles stay open; the Loader's own dlopen() reuses them. */
static int mesa_probe(const char *process)
{
    static const char *const libs[] = {
        "/system/lib/egl/libEGL_mesa.so",
        "/system/lib/egl/libGLESv2_mesa.so",
        "/system/lib/egl/libGLESv1_CM_mesa.so",
        NULL
    };
    int i;

    if (!kobo_cpu_has_neon("/proc/cpuinfo")) {
        if (__android_log_print)
            __android_log_print(LOG_ERROR, KOBO_EGL_TAG,
                                "%s: CPU ohne NEON - Mesa (NEON-Build) wird nicht geladen, nutze libGLES_android.so",
                                process);
        return 0;
    }
    for (i = 0; libs[i]; i++) {
        if (access(libs[i], R_OK) != 0) {
            if (__android_log_print)
                __android_log_print(LOG_ERROR, KOBO_EGL_TAG,
                                    "%s: %s fehlt - Mesa nicht installiert, nutze libGLES_android.so (nur GLES 1.x)",
                                    process, libs[i]);
            return 0;
        }
        if (!dlopen(libs[i], RTLD_NOW | RTLD_LOCAL)) {
            const char *err = dlerror();
            if (__android_log_print)
                __android_log_print(LOG_ERROR, KOBO_EGL_TAG,
                                    "%s: dlopen(%s) fehlgeschlagen: %s - Fallback auf libGLES_android.so (nur GLES 1.x)",
                                    process, libs[i], err ? err : "unbekannt");
            return 0;
        }
    }
    if (__android_log_print)
        __android_log_print(LOG_INFO, KOBO_EGL_TAG, "%s: Mesa (GLES2) geladen", process);
    install_crash_reporter(process);
    return 1;
}

/* Die Mesa-Bibliotheken sind mit -mfpu=neon gebaut (scripts/05-mesa.sh). Auf einer CPU ohne NEON waere
 * das ein SIGILL im App-Prozess, deshalb vorher /proc/cpuinfo pruefen. Nur auf ARM sinnvoll; auf dem
 * Host (x86-Tests) gibt es kein "Features"-Feld und das Ergebnis ist immer "ja". */
int kobo_cpu_has_neon(const char *cpuinfo_path)
{
    char buf[4096];
    char *line;
    ssize_t r;
    int saw_features = 0;
    int fd = open(cpuinfo_path, O_RDONLY | O_CLOEXEC);

    if (fd < 0)
        return 1;
    r = read(fd, buf, sizeof buf - 1);
    close(fd);
    if (r <= 0)
        return 1;
    buf[r] = 0;
    for (line = buf; line; ) {
        char *eol = strchr(line, '\n');
        if (eol)
            *eol = 0;
        if (strncmp(line, "Features", 8) == 0) {
            saw_features = 1;
            if (strstr(line, " neon") || strstr(line, " asimd"))
                return 1;
        }
        line = eol ? eol + 1 : NULL;
    }
    return saw_features ? 0 : 1;
}

/* Interposes libcutils' property_get() for libEGL.so only. */
int property_get(const char *key, char *value, const char *default_value)
{
    static char process[256];
    static int disabled = -1, all_apps = -1, probed = -1;
    Dl_info info;
    int from_egl = 0;
    const char *forced;

    if (disabled < 0) {
        /* A file /data/local/kobo-gles-off turns the Mesa path off. */
        disabled = access("/data/local/kobo-gles-off", F_OK) == 0;
        /* KOBO_GLES_APPS=0 (env or /dev/kobo/tuning): only browsers get Mesa. */
        all_apps = kobo_tunable("KOBO_GLES_APPS", 1) != 0;
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
    /* Mesa nur pruefen, wenn dieser Prozess es ueberhaupt bekommen soll (einmal je Prozess;
     * ein Zygote-Fork erbt kein Ergebnis, weil der Name erst nach dem Fork feststeht). */
    if (from_egl && !disabled && kobo_egl_process_wants_mesa(process, all_apps)) {
        if (probed < 0)
            probed = mesa_probe(process);
    }
    forced = kobo_egl_override(key, process, from_egl, probed > 0, disabled, all_apps);
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
