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
 * Antwort "<code> <seq> <text>\0". Wir melden das emulierte Primaer-Volume (EXTERNAL_STORAGE) als Mounted (110-Zeile)
 * und quittieren jedes Kommando mit 200 (Command okay).
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

/* Eine "volume list"-Zeile: "110 <seq> <label> <pfad> <state>", state 4 = Mounted (VolumeState.Mounted).
 * Ohne diese Zeilen kennt MountService keinen Status -> getExternalStorageState() = "removed"
 * -> Chrome/Editor: "No SD card", Schreiben schlaegt fehl. */
size_t kv_volume_line(const char *cmd, const char *path, char *out, size_t cap)
{
    char seq[24]; size_t i = 0; int n;
    while (cmd[i] && cmd[i] != ' ' && i < sizeof seq - 1) { if (cmd[i] < '0' || cmd[i] > '9') return 0; seq[i] = cmd[i]; i++; }
    if (i == 0 || !path || path[0] != '/') return 0;
    seq[i] = 0;
    n = snprintf(out, cap, "110 %s sdcard %s 4", seq, path);
    if (n < 0 || (size_t)n >= cap) return 0;
    return (size_t)n;
}

/* "<seq> volume mkdirs <pfad>": liefert den Zielpfad, wenn er unter dem Volume <vol> liegt und kein ".."
 * enthaelt (sonst 0). Echtes vold legt die Verzeichnisse an; MountService.mkdirs() ruft das fuer
 * Android/data/<paket>/files auf. Ohne Anlegen erzeugt die erste App die Ordner mit umask 077 (0700). */
size_t kv_mkdirs_path(const char *cmd, const char *vol, char *out, size_t cap)
{
    static const char key[] = " volume mkdirs ";
    size_t i = 0, vl, pl;
    const char *p;
    while (cmd[i] >= '0' && cmd[i] <= '9') i++;
    if (i == 0 || strncmp(cmd + i, key, sizeof key - 1) != 0 || !vol || vol[0] != '/') return 0;
    p = cmd + i + sizeof key - 1;
    vl = strlen(vol);
    if (strncmp(p, vol, vl) != 0 || (p[vl] != '/' && p[vl] != 0)) return 0;
    if (strstr(p, "..")) return 0;
    pl = strlen(p);
    while (pl > 1 && p[pl - 1] == '/') pl--;
    if (pl == 0 || pl >= cap) return 0;
    memcpy(out, p, pl); out[pl] = 0;
    return pl;
}

#ifndef KOBO_VOLD_TEST
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#define KV_MAX_VOL 4
static char vols[KV_MAX_VOL][128]; static int nvols;

/* Pfade aus /system/etc/kobo-vold.volumes (eine pro Zeile), sonst EXTERNAL_STORAGE, sonst Default. */
static void load_volumes(void)
{
    FILE *f = fopen("/system/etc/kobo-vold.volumes", "r");
    char line[128];
    if (f) {
        while (nvols < KV_MAX_VOL && fgets(line, sizeof line, f)) {
            size_t l = strlen(line);
            while (l && (line[l-1] == '\n' || line[l-1] == '\r' || line[l-1] == ' ')) line[--l] = 0;
            if (line[0] == '/') strcpy(vols[nvols++], line);
        }
        fclose(f);
    }
    if (!nvols) {
        const char *e = getenv("EXTERNAL_STORAGE");
        strncpy(vols[0], (e && e[0] == '/') ? e : "/storage/sdcard", sizeof vols[0] - 1);
        nvols = 1;
    }
}

/* Legt <path> rekursiv an: alle Ebenen ab dem Volume mit 0777 (umask-unabhaengig, wie FAT-Speicher).
 * Ordner unterhalb von Android/data|obb/<paket> gehoeren der uid der App (aus /data/data/<paket>). */
static int make_dirs(const char *vol, const char *path)
{
    char cur[256]; size_t vl = strlen(vol), n = strlen(path), i;
    unsigned uid = 0; int have_uid = 0; char pkg[128]; pkg[0] = 0;
    const char *a = strstr(path + vl, "/Android/data/");
    if (!a) a = strstr(path + vl, "/Android/obb/");
    if (a) {
        const char *q = strchr(a + 1, '/'); q = q ? strchr(q + 1, '/') : 0;   /* hinter Android/data/ */
        if (q) {
            const char *e = strchr(q + 1, '/'); size_t l = e ? (size_t)(e - (q + 1)) : strlen(q + 1);
            if (l > 0 && l < sizeof pkg) {
                char dd[200]; struct stat st;
                memcpy(pkg, q + 1, l); pkg[l] = 0;
                snprintf(dd, sizeof dd, "/data/data/%s", pkg);
                if (stat(dd, &st) == 0) { uid = st.st_uid; have_uid = 1; }
            }
        }
    }
    if (n >= sizeof cur) return -1;
    for (i = vl; i <= n; i++) {
        if (path[i] != '/' && path[i] != 0) continue;
        if (i == vl) continue;
        memcpy(cur, path, i); cur[i] = 0;
        if (mkdir(cur, 0777) == 0) {
            chmod(cur, 0777);
            if (have_uid && pkg[0] && strstr(cur, pkg)) chown(cur, uid, uid);
        } else if (errno != EEXIST) return -1;
    }
    return 0;
}

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
                char rep[160]; size_t n; int v;
                const char *cmd = buf + start; size_t sl = 0;
                while (cmd[sl] >= '0' && cmd[sl] <= '9') sl++;
                if (sl && strncmp(cmd + sl, " volume list", 12) == 0)
                    for (v = 0; v < nvols; v++) {
                        n = kv_volume_line(cmd, vols[v], rep, sizeof rep - 1);
                        if (n) { rep[n] = 0; if (write(c, rep, n + 1) < 0) return; }
                    }
                {   /* volume mkdirs: wirklich anlegen, Fehler als 400 melden */
                    char dp[256]; int done = 0, ok = 1;
                    for (v = 0; v < nvols && !done; v++)
                        if (kv_mkdirs_path(cmd, vols[v], dp, sizeof dp)) { done = 1; ok = make_dirs(vols[v], dp) == 0; }
                    if (done && !ok) {
                        n = (size_t)snprintf(rep, sizeof rep - 1, "400 %.*s Failed to create dirs", (int)sl, cmd);
                        if (write(c, rep, n + 1) < 0) return;
                        start = i + 1; continue;
                    }
                }
                n = kv_reply(cmd, rep, sizeof rep - 1);
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
    load_volumes();
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
