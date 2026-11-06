/* SPDX-License-Identifier: MIT
 * Ersatz fuer den Android-Kernel-Logger (dev/log), den der Kobo-Kernel nicht hat und den es ohne
 * logd in Android 5.0.2 auch nicht gibt. libkobofb.so wird per LD_PRELOAD in jeden Prozess geladen und
 * ueberlagert die liblog-Einstiegspunkte; die Meldungen landen in KOBO_LOG_FILE (Standard
 * /data/local/tmp/android.log). Kein Android-Header noetig, Signaturen stehen hier. */
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void emit(int prio, const char *tag, const char *msg)
{
    static const char P[] = "?  VDIWEF";
    const char *path = getenv("KOBO_LOG_FILE");
    char buf[1024]; int n, fd, saved = errno;
    if (prio < 4) return; /* Verbose/Debug weglassen */
    if (!path || !*path) path = "/data/local/tmp/android.log";
    n = snprintf(buf, sizeof(buf), "%c/%s(%d): %s", prio >= 0 && prio <= 8 ? P[prio] : '?',
                 tag ? tag : "?", (int)getpid(), msg ? msg : "");
    if (n < 0) { errno = saved; return; }
    if ((size_t)n > sizeof(buf) - 2) n = (int)sizeof(buf) - 2;
    buf[n++] = '\n';
    fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0666);
    if (fd >= 0) { if (write(fd, buf, (size_t)n) < 0) { /* ignore */ } close(fd); }
    errno = saved;
}

int __android_log_write(int prio, const char *tag, const char *text)
{ emit(prio, tag, text); return 1; }

int __android_log_buf_write(int bufid, int prio, const char *tag, const char *text)
{ (void)bufid; emit(prio, tag, text); return 1; }

int __android_log_vprint(int prio, const char *tag, const char *fmt, va_list ap)
{ char b[800]; vsnprintf(b, sizeof(b), fmt, ap); emit(prio, tag, b); return 1; }

int __android_log_print(int prio, const char *tag, const char *fmt, ...)
{ va_list ap; char b[800]; va_start(ap, fmt); vsnprintf(b, sizeof(b), fmt, ap); va_end(ap); emit(prio, tag, b); return 1; }

int __android_log_buf_print(int bufid, int prio, const char *tag, const char *fmt, ...)
{ va_list ap; char b[800]; (void)bufid; va_start(ap, fmt); vsnprintf(b, sizeof(b), fmt, ap); va_end(ap); emit(prio, tag, b); return 1; }

void __android_log_assert(const char *cond, const char *tag, const char *fmt, ...)
{
    char b[800];
    if (fmt) { va_list ap; va_start(ap, fmt); vsnprintf(b, sizeof(b), fmt, ap); va_end(ap); }
    else snprintf(b, sizeof(b), "Assertion failed: %s", cond ? cond : "?");
    emit(7, tag, b);
    abort();
}
