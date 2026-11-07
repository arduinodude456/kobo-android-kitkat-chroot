/* SPDX-License-Identifier: MIT */
/*
 * Minimaler vold-Ersatz fuer den Kobo-Chroot (KitKat/API 19).
 *
 * Im Chroot laeuft kein echtes vold (Kernel-/Mount-Zugriff unerwuenscht). system_server
 * (MountService) wartet aber endlos ("Thread main still waiting for MountService ready...",
 * VoldConnector: "No such file or directory"), bis es sich mit dem Socket /dev/socket/vold
 * verbunden und "volume list" beantwortet bekommen hat -> Boot bleibt vor dem Homescreen haengen.
 *
 * Protokoll (NativeDaemonConnector): Kommando "<seq> <cmd> [args]\0",
 * Antwort "<code> <seq> <text>\0". Wir melden keine Volumes und quittieren jedes Kommando
 * mit 200 (Command okay). Primaerer Speicher ist /data/media bzw. emuliert, kein Wechselmedium.
 */
#include <stddef.h>
#include <stdio.h>
#include <string.h>

/* Baut die Antwort fuer ein Kommando (ohne abschliessendes NUL). Liefert Laenge oder 0 bei ungueltiger Eingabe. */
size_t kv_reply(const char *cmd, char *out, size_t cap)
{
    char seq[24]; size_t i = 0; int n;
    while (cmd[i] && cmd[i] != ' ' && i < sizeof seq - 1) { if (cmd[i] < '0' || cmd[i] > '9') return 0; seq[i] = cmd[i]; i++; }
    if (i == 0) return 0;
    seq[i] = 0;
    n = snprintf(out, cap, "200 %s %s", seq, strstr(cmd, " volume list") == cmd + i ? "Volumes listed." : "Command succeeded");
    if (n < 0 || (size_t)n >= cap) return 0;
    return (size_t)n;
}

#ifndef KOBO_VOLD_TEST
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

static void handle(int c)
{
    char buf[1024]; size_t len = 0;
    for (;;) {
        ssize_t r = read(c, buf + len, sizeof buf - len - 1);
        size_t start = 0, i;
        if (r <= 0) return;
        len += (size_t)r;
        for (i = 0; i < len; i++) {
            if (buf[i] == 0) {
                char rep[96]; size_t n = kv_reply(buf + start, rep, sizeof rep - 1);
                if (n) { rep[n] = 0; if (write(c, rep, n + 1) < 0) return; }
                start = i + 1;
            }
        }
        if (start) { memmove(buf, buf + start, len - start); len -= start; }
        else if (len >= sizeof buf - 1) len = 0;   /* ueberlange Zeile verwerfen */
    }
}

int main(void)
{
    int s = -1;
    const char *env = getenv("ANDROID_SOCKET_vold");
    if (env) s = atoi(env);                       /* von init ("socket vold ...") angelegt */
    if (s < 0) {                                  /* Fallback: selbst anlegen */
        struct sockaddr_un a; memset(&a, 0, sizeof a);
        a.sun_family = AF_UNIX; strcpy(a.sun_path, "/dev/socket/vold");
        unlink(a.sun_path);
        s = socket(AF_UNIX, SOCK_STREAM, 0);
        if (s < 0 || bind(s, (struct sockaddr *)&a, sizeof a) < 0) return 1;
        chmod(a.sun_path, 0660);
    }
    if (listen(s, 4) < 0) return 1;
    for (;;) {
        int c = accept(s, NULL, NULL);
        if (c < 0) { if (errno == EINTR) continue; sleep(1); continue; }
        handle(c);
        close(c);
    }
}
#endif
