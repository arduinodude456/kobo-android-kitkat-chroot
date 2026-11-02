/* SPDX-License-Identifier: MIT
 * Container entry point. Never runs Android init in the host PID namespace.
 * All host-visible mounts are prepared by android.sh beneath its own run/.
 */
#define _GNU_SOURCE
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#ifndef CLONE_NEWNS
#define CLONE_NEWNS 0x00020000
#endif
#ifndef CLONE_NEWPID
#define CLONE_NEWPID 0x20000000
#endif
static volatile sig_atomic_t child_pid;
static void terminate_child(int sig) {
    (void)sig;
    /* PID 1 may ignore TERM. Kill only our private namespace init; the kernel
     * tears down its descendants. android.sh stops writers and syncs first. */
    if (child_pid > 0) kill((pid_t)child_pid, SIGKILL);
}
static void die(const char *what) { perror(what); exit(1); }
static int isolated(const char *root, int check) {
    pid_t p;
    int status;
    if (syscall(__NR_unshare, CLONE_NEWNS | CLONE_NEWPID) < 0)
        die("unshare: kernel needs CONFIG_NAMESPACES, CONFIG_PID_NS and CONFIG_MNT_NS");
    if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) < 0) die("make mounts private");
    p = fork();
    if (p < 0) die("fork PID namespace");
    if (!p) {
        char proc[PATH_MAX];
        if (getpid() != 1) { fputs("Refusing to run init outside a private PID namespace\n", stderr); _exit(1); }
        if (check) _exit(0);
        if (snprintf(proc, sizeof proc, "%s/proc", root) >= (int)sizeof proc) _exit(1);
        if (mount("proc", proc, "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL)) die("private proc mount");
        if (chdir(root) || chroot(".") || chdir("/")) die("chroot");
        if (access("/kobo-chroot", F_OK)) die("rootfs lacks kobo-chroot marker");
        /* No host environment, no inherited LD_PRELOAD or library paths. */
        {
            char *const argv[] = { "/init", NULL };
            char *const env[] = { "PATH=/sbin:/system/bin:/system/xbin", "ANDROID_ROOT=/system", "ANDROID_DATA=/data", NULL };
            execve("/init", argv, env);
        }
        die("exec Android init");
    }
    child_pid = p;
    signal(SIGTERM, terminate_child);
    signal(SIGINT, terminate_child);
    while (waitpid(p, &status, 0) < 0) {
        if (errno != EINTR) die("waitpid");
    }
    child_pid = 0;
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
int main(int argc, char **argv) {
    char resolved[PATH_MAX];
    const char *root = NULL;
    int check = 0, i;
    if (geteuid()) { fputs("kobo-container requires root\n", stderr); return 1; }
    for (i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--check")) check = 1;
        else if (!strcmp(argv[i], "--root") && i + 1 < argc) root = argv[++i];
        else { fputs("Usage: kobo-container --check | --root ROOTFS\n", stderr); return 2; }
    }
    if (!check) {
        if (!root || !realpath(root, resolved) || !strcmp(resolved, "/")) {
            fputs("Invalid rootfs path\n", stderr); return 2;
        }
        root = resolved;
    }
    return isolated(root, check);
}
