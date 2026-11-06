#!/bin/sh
# SPDX-License-Identifier: MIT
# Invoke with sh: executable permission bits may not survive a FAT/ZIP copy.
set -eu
BASE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
RUN="$BASE/run"
ROOTFS="$RUN/rootfs"
CONFIG="$BASE/config"
# shellcheck source=/dev/null
[ ! -f "$CONFIG" ] || . "$CONFIG"
KOBO_BINDER_DEVICE=${KOBO_BINDER_DEVICE:-/dev/binder}
KOBO_ASHMEM_DEVICE=${KOBO_ASHMEM_DEVICE:-/dev/ashmem}
KOBO_ALLOW_UNSAFE_NO_NAMESPACES=${KOBO_ALLOW_UNSAFE_NO_NAMESPACES:-1}
export KOBO_BINDER_DEVICE KOBO_ASHMEM_DEVICE KOBO_ALLOW_UNSAFE_NO_NAMESPACES
mkdir -p "$RUN"
fail() { echo "Android: $*" >&2; exit 1; }
root_required() { [ "$(id -u)" = 0 ] || fail 'Root erforderlich (aus KOReader starten).'; }
mounted() { awk -v p="$1" '$2 == p {found=1} END {exit !found}' /proc/mounts; }
running() {
    [ -r "$RUN/runner.pid" ] || return 1
    pid=$(cat "$RUN/runner.pid")
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ -r "/proc/$pid/cmdline" ] || return 1
    tr '\000' '\n' < "/proc/$pid/cmdline" | grep -F -x "$BASE/android.sh" >/dev/null 2>&1 || return 1
    kill -0 "$pid" 2>/dev/null
}
orphan_active() {
    for name in container vnc; do
        [ -r "$RUN/$name.pid" ] || continue
        saved_pid=$(cat "$RUN/$name.pid")
        case "$saved_pid" in ''|*[!0-9]*) continue ;; esac
        exe=$(readlink "/proc/$saved_pid/exe" 2>/dev/null || true)
        case "$exe" in "$BASE/bin/kobo-container"|"$BASE/bin/kobo-vnc")
            kill -0 "$saved_pid" 2>/dev/null && return 0 ;;
        esac
    done
    return 1
}
check() {
    root_required
    [ -x "$BASE/bin/kobo-container" ] || fail 'bin/kobo-container fehlt oder ist nicht ausführbar.'
    [ -x "$BASE/bin/kobo-vnc" ] || fail 'bin/kobo-vnc fehlt oder ist nicht ausführbar.'
    "$BASE/bin/kobo-container" --check
    "$BASE/bin/kobo-vnc" --check
    grep -qw ext4 /proc/filesystems || fail 'Kernel unterstützt kein ext4.'
    [ -e /dev/loop-control ] || [ -e /dev/loop0 ] || fail 'Kein Loop-Gerät vorhanden.'
    echo 'Kernel-Vorprüfung erfolgreich; dies ersetzt keinen Android-Gerätetest.'
}
copy_node() {
    src=$1 dst=$2 mode=$3
    [ -c "$src" ] || fail "Zeichengerät fehlt: $src"
    hexmajor=$(stat -c '%t' "$src")
    hexminor=$(stat -c '%T' "$src")
    mknod "$dst" c "$((0x$hexmajor))" "$((0x$hexminor))"
    chmod "$mode" "$dst"
}
dlog() { echo "DIAG: $*"; }
try_mount() {
    desc=$1; shift
    if out=$("$@" 2>&1); then dlog "$desc: OK"; return 0; fi
    dlog "$desc: FEHLER ${out:-unbekannt}"; return 1
}
proc_diag() {
    dlog "Kernel $(uname -r) $(uname -m)"
    dlog "Shell ns: mnt=$(readlink /proc/$$/ns/mnt 2>&1) pid=$(readlink /proc/$$/ns/pid 2>&1)"
    dlog "Dateisysteme: $(grep -w proc /proc/filesystems | tr '\n' ' ')"
    dlog "Ziel: $(ls -ld "$ROOTFS/proc" 2>&1)"
    dlog "Rootfs-Mount: $(grep " $ROOTFS " /proc/mounts | head -n 1)"
    t="$RUN/proctest"; mkdir -p "$t"
    if try_mount "Test proc auf Hostpfad" mount -t proc proc "$t"; then umount "$t" 2>/dev/null || true; fi
    if try_mount "Test bind auf Hostpfad" mount -o bind /proc "$t"; then umount "$t" 2>/dev/null || true; fi
    rmdir "$t" 2>/dev/null || true
    dlog "dmesg: $(dmesg 2>/dev/null | tail -n 3 | tr '\n' '|')"
}
prepare_proc() {
    proc_diag
    try_mount "proc im Rootfs (nosuid,nodev,noexec)" mount -t proc -o nosuid,nodev,noexec proc "$ROOTFS/proc" && return 0
    try_mount "proc im Rootfs" mount -t proc proc "$ROOTFS/proc" && return 0
    try_mount "bind /proc" mount -o bind /proc "$ROOTFS/proc" && return 0
    try_mount "rbind /proc" mount -o rbind /proc "$ROOTFS/proc" && return 0
    return 1
}
kill_rootfs_procs() {
    # Kernel has no PID namespace: init's children would survive init. Kill every
    # process whose root is exactly our rootfs so the unmounts can succeed.
    for d in /proc/[0-9]*; do
        pid=${d#/proc/}
        [ "$pid" != "$$" ] || continue
        r=$(readlink "$d/root" 2>/dev/null || true)
        if [ "$r" = "$ROOTFS" ]; then kill -KILL "$pid" 2>/dev/null || true; fi
    done
    sleep 1
}
watchdog() {
    # Notbremse: Android beenden, bevor der Kobo wegen Speichermangel einfriert.
    min_kb=${KOBO_MIN_FREE_KB:-60000}
    : > "$BASE/watchdog.log"
    while kill -0 "$container_pid" 2>/dev/null; do
        avail=$(awk '/^MemAvailable:/{a=$2} /^MemFree:/{f=$2} /^Cached:/{c=$2} END{print (a ? a : f + c)}' /proc/meminfo)
        echo "$(date +%T) frei_kb=$avail limit_kb=$min_kb" > "$BASE/watchdog.last"
        case "$avail" in ''|*[!0-9]*) avail=999999 ;; esac
        if [ "$avail" -lt "$min_kb" ]; then
            echo "$(date +%T) WATCHDOG: nur $avail kB frei, Android wird beendet" | tee -a "$BASE/watchdog.log"
            kill_rootfs_procs
            return 0
        fi
        sleep 1
    done
}
unmount_tree() {
    # Android-init (stock) stapelt eigene Mounts (tmpfs auf /dev, proc, sysfs, devpts) auf unsere.
    # Deshalb von oben nach unten und mehrfach aushaengen, bis nichts mehr unter dem Rootfs haengt.
    pass=0
    while [ "$pass" -lt 12 ]; do
        list=$(awk -v r="$ROOTFS" -v s="$RUN/shared" '$2 == r || index($2, r "/") == 1 || $2 == s { print $2 }' /proc/mounts | sort -r)
        [ -n "$list" ] || return 0
        for m in $list; do umount "$m" 2>/dev/null || true; done
        pass=$((pass + 1))
    done
    echo "Android: Mounts bleiben belegt:" >&2
    awk -v r="$ROOTFS" 'index($2, r) == 1 { print "  " $2 }' /proc/mounts >&2
    return 1
}
patch_init_rc() {
    # Das stock-init der Emulator-Ramdisk mountet ein frisches tmpfs auf /dev und versteckt damit
    # alle vom Host vorbereiteten Geraete (binder, ashmem, null, input, kobo). Ohne ueventd gibt es
    # keinen Weg zurueck. Loesung: Knoten liegen zusaetzlich unter /hostdev und werden in /dev verlinkt.
    rc="$ROOTFS/init.rc"
    [ -f "$rc" ] || return 0
    grep -q 'KOBO_HOSTDEV_V1' "$rc" && return 0
    links="null zero random urandom tty binder ashmem input kobo"
    [ ! -d /dev/log ] || links="$links log"
    tmp="$RUN/init.rc.new"
    awk -v links="$links" '
        $1 == "mkdir" && ($2 == "/dev/kobo" || $2 == "/dev/input") { next }
        { print }
        $1 == "on" && $2 == "early-init" && NF == 2 && !done {
            print "    # KOBO_HOSTDEV_V1: stock init mounts a fresh tmpfs over /dev; re-expose host-prepared nodes."
            print "    write /dev/.coldboot_done 1"
            n = split(links, a, " ")
            for (i = 1; i <= n; i++) print "    symlink /hostdev/" a[i] " /dev/" a[i]
            done = 1
        }' "$rc" > "$tmp" || { rm -f "$tmp"; fail 'init.rc konnte nicht angepasst werden.'; }
    grep -q 'KOBO_HOSTDEV_V1' "$tmp" || { rm -f "$tmp"; fail 'init.rc: "on early-init" nicht gefunden.'; }
    cat "$tmp" > "$rc" && rm -f "$tmp"
    echo "init.rc angepasst (KOBO_HOSTDEV_V1)"
}
# ---- Diagnose: Stufentest (sh android.sh stages) -> stages.log -------------------------------------
# Prueft einzeln, WO der Chroot scheitert. Startet kein init, kein zygote; alles wird danach wieder abgebaut.
stages_body() {
    set +e
    ok() { echo "ERGEBNIS $1: OK"; }
    bad() { echo "ERGEBNIS $1: FEHLER ($2)"; }
    echo "=== STUFE 0: Umgebung"
    echo "uid=$(id -u) kernel=$(uname -r) $(uname -m)"
    grep -E 'MemTotal|MemAvailable' /proc/meminfo
    ls -l "$BASE/rootfs.img" "$BASE/rootfs.img.gz" 2>&1
    if [ ! -f "$BASE/rootfs.img" ]; then
        echo "rootfs.img fehlt, entpacke ..."
        sh "$BASE/install.sh" 2>&1 || { bad 0 "install.sh"; return 1; }
    fi
    ok 0
    echo "=== STUFE 1: Kernel-Vorpruefung"
    if ( check ) 2>&1; then ok 1; else bad 1 "check"; return 1; fi
    echo "=== STUFE 2: ext4-Image per Loop einbinden"
    mkdir -p "$ROOTFS"
    out=$(mount -t ext4 -o loop,noatime,nosuid "$BASE/rootfs.img" "$ROOTFS" 2>&1) || { bad 2 "$out"; return 1; }
    [ -f "$ROOTFS/kobo-chroot" ] || { bad 2 "Sicherheitsmarker kobo-chroot fehlt"; return 1; }
    echo "Rootfs-Marker: $(cat "$ROOTFS/kobo-chroot")  Dateien in /system/bin: $(ls "$ROOTFS/system/bin" | wc -l)"
    ok 2
    echo "=== STUFE 3: Android-Shell im Chroot (ARM-Linker, bionic)"
    [ ! -L "$ROOTFS/proc" ] || rm -f "$ROOTFS/proc"
    [ ! -L "$ROOTFS/sys" ] || rm -f "$ROOTFS/sys"
    mkdir -p "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/data/local/tmp"
    prepare_proc >/dev/null 2>&1 || echo "WARNUNG: proc nicht gemountet"
    mount -t tmpfs -o size=8m,mode=0755,nosuid tmpfs "$ROOTFS/dev" 2>&1
    for node in null zero random urandom tty; do copy_node "/dev/$node" "$ROOTFS/dev/$node" 0666; done
    copy_node "$KOBO_BINDER_DEVICE" "$ROOTFS/dev/binder" 0666
    copy_node "$KOBO_ASHMEM_DEVICE" "$ROOTFS/dev/ashmem" 0666
    CHROOT_BIN=$(command -v chroot) || { bad 3 "chroot fehlt"; return 1; }
    out=$("$CHROOT_BIN" "$ROOTFS" /system/bin/sh -c 'echo SH_OK; ls /system' 2>&1)
    echo "$out"
    case "$out" in *SH_OK*) ok 3 ;; *) bad 3 "Android-sh startet nicht"; return 1 ;; esac
    echo "=== STUFE 4: Binder-ABI Ende-zu-Ende (servicemanager + 'service list' mit Shim)"
    rm -f "$ROOTFS/data/local/tmp/kobo-binder.log"
    PRE='export LD_PRELOAD=/system/lib/libkobofb.so KOBO_BINDER_LOG=/data/local/tmp/kobo-binder.log'
    "$CHROOT_BIN" "$ROOTFS" /system/bin/sh -c "$PRE; exec /system/bin/servicemanager" > "$RUN/sm.out" 2>&1 &
    smpid=$!
    sleep 3
    if kill -0 "$smpid" 2>/dev/null; then echo "servicemanager laeuft (PID $smpid)"; else echo "servicemanager ist sofort beendet:"; cat "$RUN/sm.out"; fi
    out=$("$CHROOT_BIN" "$ROOTFS" /system/bin/sh -c "$PRE; /system/bin/service list" 2>&1)
    echo "service list: $out"
    kill "$smpid" 2>/dev/null; sleep 1; kill -KILL "$smpid" 2>/dev/null
    echo "--- servicemanager-Ausgabe:"; cat "$RUN/sm.out" 2>/dev/null
    echo "--- Binder-Shim-Log:"; cat "$ROOTFS/data/local/tmp/kobo-binder.log" 2>&1 | tail -n 30
    case "$out" in *"Found"*) ok 4 ;; *) bad 4 "Binder-Kommunikation funktioniert nicht" ;; esac
    echo "=== STUFE 5: Kernel-Meldungen (Binder/Ashmem)"
    dmesg 2>/dev/null | grep -iE 'binder|ashmem|selinux' | tail -n 15
    echo "=== ENDE"
}
stages() {
    root_required
    running && fail 'Android laeuft; erst stop.'
    mkdir "$RUN/lock" 2>/dev/null || fail 'Verwaister Zustand. Erst sh android.sh recover ausfuehren.'
    ( stages_body ) > "$BASE/stages.log" 2>&1 || true
    pkill -f "$ROOTFS" 2>/dev/null || true
    kill_rootfs_procs
    unmount_tree >> "$BASE/stages.log" 2>&1 || echo "WARNUNG: Mounts blieben belegt" >> "$BASE/stages.log"
    rm -f "$RUN/sm.out"
    mounted "$ROOTFS" || rmdir "$RUN/lock" 2>/dev/null || true
    echo "Stufentest fertig: $BASE/stages.log"
}
# ---- Diagnose: Boot-Zeitachse (laeuft waehrend run im Hintergrund) -> bootwatch.log ---------------
bootwatch() {
    set +e
    w="$BASE/bootwatch.log"; : > "$w"; i=0
    gp() { chroot "$ROOTFS" /system/bin/getprop "$1" 2>/dev/null | tr -d '\r'; }
    while [ "$i" -lt 60 ] && kill -0 "$container_pid" 2>/dev/null; do
        sleep 10; i=$((i + 1)); n=0
        for d in /proc/[0-9]*; do [ "$(readlink "$d/root" 2>/dev/null)" = "$ROOTFS" ] && n=$((n + 1)); done
        echo "$(date +%T) t=${i}0s procs=$n boot=$(gp sys.boot_completed) sm=$(gp init.svc.servicemanager) sf=$(gp init.svc.surfaceflinger) zygote=$(gp init.svc.zygote) netd=$(gp init.svc.netd) frei_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)" >> "$w"
        # Absturzursache sichtbar machen: logcat (Fehler/Fatal) und neuester Tombstone
        tail -n 120 "$ROOTFS/data/local/tmp/android.log" > "$BASE/logcat.txt" 2>&1
        t=$(ls -t "$ROOTFS"/data/tombstones 2>/dev/null | head -n 1)
        if [ -n "$t" ]; then head -n 60 "$ROOTFS/data/tombstones/$t" > "$BASE/tombstone.txt" 2>/dev/null; fi
        [ "$(gp sys.boot_completed)" = 1 ] && { echo "BOOT FERTIG nach ${i}0s" >> "$w"; break; }
    done
}
cleanup() {
    trap - EXIT INT TERM HUP
    if [ -n "${container_pid:-}" ]; then
        kill -TERM "$container_pid" 2>/dev/null || true
        wait "$container_pid" 2>/dev/null || true
    fi
    if [ -n "${watchdog_pid:-}" ]; then kill "$watchdog_pid" 2>/dev/null || true; fi
    if [ -n "${watch_pid:-}" ]; then kill "$watch_pid" 2>/dev/null || true; fi
    if [ -f "$BASE/android-init.log" ] || [ -n "${container_pid:-}" ]; then
        dmesg 2>/dev/null | grep -E 'init:|<init>|servicemanager|zygote|surfaceflinger|binder' | tail -n 200 >> "$BASE/android-init.log" 2>/dev/null || true
    fi
    if [ -n "${vnc_pid:-}" ]; then
        kill -TERM "$vnc_pid" 2>/dev/null || true
        wait "$vnc_pid" 2>/dev/null || true
    fi
    mounted "$ROOTFS" && kill_rootfs_procs
    if [ -f "$ROOTFS/dev/kmsg" ]; then
        cat "$ROOTFS/dev/kmsg" >> "$BASE/android-init.log" 2>/dev/null || true
    fi
    sync
    unmount_failed=0
    unmount_tree || unmount_failed=1
    rm -f "$RUN/runner.pid" "$RUN/container.pid" "$RUN/vnc.pid" "$RUN/ready"
    if [ "$unmount_failed" = 0 ]; then rmdir "$RUN/lock" 2>/dev/null || true; fi
}
run() {
    root_required
    mkdir "$RUN/lock" 2>/dev/null || fail 'Schon gestartet oder alte Mounts vorhanden; status/recover prüfen.'
    container_pid='' vnc_pid='' watchdog_pid='' watch_pid=''
    trap cleanup EXIT
    trap 'exit 0' INT TERM HUP
    echo $$ > "$RUN/runner.pid"
    check
    [ -f "$BASE/rootfs.img" ] || sh "$BASE/install.sh"
    mkdir -p "$ROOTFS" "$RUN/shared"
    mounted "$ROOTFS" && fail 'Rootfs ist bereits gemountet.'
    mount -t ext4 -o loop,noatime,nosuid "$BASE/rootfs.img" "$ROOTFS"
    [ -f "$ROOTFS/kobo-chroot" ] || fail 'Falsches Rootfs: Sicherheitsmarker fehlt.'
    patch_init_rc
    mkdir -p "$ROOTFS/data/local/tmp"
    chmod 0777 "$ROOTFS/data/local/tmp"
    # Shim-Log vorab anlegen und fuer alle uids beschreibbar machen (SurfaceFlinger laeuft als system)
    : > "$ROOTFS/data/local/tmp/kobo-binder.log"; chmod 0666 "$ROOTFS/data/local/tmp/kobo-binder.log"
    : > "$ROOTFS/data/local/tmp/android.log"; chmod 0666 "$ROOTFS/data/local/tmp/android.log"
    rm -rf "$ROOTFS/data/tombstones" 2>/dev/null || true; rm -f "$BASE/logcat.txt" "$BASE/tombstone.txt"
    # Replace image-provided dangling proc/sys symlinks with mountpoint dirs.
    # The official image may inherit these links from its emulator product.
    [ ! -L "$ROOTFS/proc" ] || rm -f "$ROOTFS/proc"
    [ ! -L "$ROOTFS/sys" ] || rm -f "$ROOTFS/sys"
    mkdir -p "$ROOTFS/proc" "$ROOTFS/sys"
    [ -d "$ROOTFS/proc" ] || fail "Mountpoint fehlt: $ROOTFS/proc"
    proc_ready=0
    if prepare_proc; then proc_ready=1; else echo "WARNING: proc konnte nicht per Shell gemountet werden; kobo-container versucht es selbst"; fi
    mount -t tmpfs -o size=16m,mode=0755,nosuid tmpfs "$ROOTFS/dev"
    mkdir -p "$ROOTFS/dev/input" "$ROOTFS/dev/socket" "$ROOTFS/dev/graphics" "$ROOTFS/dev/kobo" "$ROOTFS/dev/pts"
    chmod 0755 "$ROOTFS/dev/input" "$ROOTFS/dev/socket"
    for node in null zero random urandom tty; do copy_node "/dev/$node" "$ROOTFS/dev/$node" 0666; done
    copy_node "$KOBO_BINDER_DEVICE" "$ROOTFS/dev/binder" 0666
    copy_node "$KOBO_ASHMEM_DEVICE" "$ROOTFS/dev/ashmem" 0666
    # Android legacy logger devices are optional. Never bind the host /dev tree.
    if [ -d /dev/log ]; then
        mkdir -p "$ROOTFS/dev/log"
        for node in main system events radio; do
            [ ! -c "/dev/log/$node" ] || copy_node "/dev/log/$node" "$ROOTFS/dev/log/$node" 0666
        done
    fi
    # init's klog output stays in this private regular file, not the host kernel log.
    : > "$ROOTFS/dev/kmsg"
    chmod 0600 "$ROOTFS/dev/kmsg"
    mount -t tmpfs -o size=4m,mode=0755,nosuid,nodev tmpfs "$RUN/shared"
    mount -o bind "$RUN/shared" "$ROOTFS/dev/kobo"
    if [ "${KOBO_PROBE:-0}" = 1 ]; then
        # Harmloser Test: nur ein Android-Shell-Befehl im Chroot, KEIN init, kein zygote.
        echo "PROBE: chroot + /system/bin/sh (ohne init)"
        CHROOT_BIN=$(command -v chroot) || fail 'chroot nicht gefunden.'
        "$CHROOT_BIN" "$ROOTFS" /system/bin/sh -c 'echo PROBE: Android-sh OK; ls /system | head -n 5; head -n 2 /proc/meminfo' 2>&1 || echo "PROBE: FEHLER Code $?"
        echo "PROBE: fertig"
        return 0
    fi
    ifconfig lo 127.0.0.1 up 2>/dev/null || ip link set lo up
    "$BASE/bin/kobo-vnc" --shared "$RUN/shared" --input-dir "$ROOTFS/dev/input" --port 5963 &
    vnc_pid=$!
    echo "$vnc_pid" > "$RUN/vnc.pid"
    tries=0
    while [ ! -f "$RUN/shared/fb.meta" ] || [ ! -f "$RUN/shared/fb.bin" ] || ! ls "$ROOTFS/dev/input"/event* >/dev/null 2>&1; do
        kill -0 "$vnc_pid" 2>/dev/null || fail 'VNC-/Eingabebrücke beendet; siehe android.log.'
        tries=$((tries + 1)); [ "$tries" -le 15 ] || fail 'VNC-/uinput-Initialisierung dauert zu lange.'
        sleep 1
    done
    chown 1000:1003 "$RUN/shared/fb.bin" "$RUN/shared/fb.meta"
    chmod 0660 "$RUN/shared/fb.bin" "$RUN/shared/fb.meta"
    chmod 0660 "$ROOTFS/dev/input"/event*
    chown 1000:1004 "$ROOTFS/dev/input"/event*
    # Zweiter Zugang zu den Geraeteknoten, der nicht von init's tmpfs auf /dev verdeckt wird.
    mkdir -p "$ROOTFS/hostdev"
    if ! mount -o rbind "$ROOTFS/dev" "$ROOTFS/hostdev" 2>/dev/null; then
        mount -o bind "$ROOTFS/dev" "$ROOTFS/hostdev" || fail 'hostdev-Bind fehlgeschlagen.'
        mount -o bind "$RUN/shared" "$ROOTFS/hostdev/kobo" || fail 'hostdev/kobo-Bind fehlgeschlagen.'
    fi
    [ -c "$ROOTFS/hostdev/binder" ] && [ -d "$ROOTFS/hostdev/kobo" ] || fail 'hostdev unvollstaendig.'
    echo "hostdev bereit: $(ls "$ROOTFS/hostdev" | tr '\n' ' ')"
    if [ "$proc_ready" = 1 ]; then
        echo "Start per Shell-chroot (kobo-container umgangen)"
        # env -i replaces PATH, so resolve host binaries to absolute paths first.
        CHROOT_BIN=$(command -v chroot) || fail 'chroot nicht gefunden.'
        ENV_BIN=$(command -v env) || fail 'env nicht gefunden.'
        SH_BIN=$(command -v sh)
        # Android soll bei Speicherknappheit zuerst vom OOM-Killer beendet werden, nicht der Kobo.
        "$SH_BIN" -c 'echo 1000 > /proc/self/oom_score_adj 2>/dev/null; exec "$@"' sh \
            "$ENV_BIN" -i PATH=/sbin:/system/bin:/system/xbin ANDROID_ROOT=/system ANDROID_DATA=/data \
            "$CHROOT_BIN" "$ROOTFS" /init &
    else
        "$BASE/bin/kobo-container" --root "$ROOTFS" &
    fi
    container_pid=$!
    echo "$container_pid" > "$RUN/container.pid"
    watchdog & watchdog_pid=$!
    bootwatch & watch_pid=$!
    touch "$RUN/ready"
    while kill -0 "$container_pid" 2>/dev/null && kill -0 "$vnc_pid" 2>/dev/null; do sleep 1; done
    echo 'Android oder die VNC-Brücke wurde beendet.'
}
case "${1:-status}" in
    check) check ;;
    start)
        root_required
        if running; then echo 'Android läuft bereits.'; exit 0; fi
        orphan_active && fail 'Verwaiste Android-Prozesse aktiv. Kobo sauber neu starten.'
        if [ -d "$RUN/lock" ]; then fail 'Verwaister Zustand. Erst sh android.sh recover ausführen.'; fi
        nohup sh "$BASE/android.sh" run >> "$BASE/android.log" 2>&1 < /dev/null &
        echo 'Android startet; Details: android.log'
        ;;
    run) run ;;
    stages) stages ;;
    probe) KOBO_PROBE=1; export KOBO_PROBE; run ;;
    stop)
        root_required
        if running; then
            # Stop important writers before terminating the private PID namespace.
            for service in zygote surfaceflinger installd; do
                chroot "$ROOTFS" /system/bin/setprop ctl.stop "$service" 2>/dev/null || true
            done
            sleep 1; sync
            pid=$(cat "$RUN/runner.pid")
            kill -TERM "$pid"
            i=0
            while running; do i=$((i + 1)); [ "$i" -le 20 ] || fail 'Stopp hängt; keine erzwungenen Unmounts vorgenommen.'; sleep 1; done
        else echo 'Android läuft nicht.'; fi
        ;;
    status)
        if running; then echo 'Android-Prozess läuft (Bootstatus separat prüfen).'; else echo 'Android gestoppt.'; fi
        if mounted "$ROOTFS"; then echo "Rootfs gemountet: $ROOTFS"; fi
        ;;
    diag) root_required; mkdir -p "$ROOTFS/proc" 2>/dev/null || true; proc_diag ;;
    exec)
        root_required; shift
        running && [ -f "$RUN/ready" ] || fail 'Android läuft nicht.'
        [ "$#" -gt 0 ] || fail 'Befehl fehlt.'
        unset LD_PRELOAD LD_LIBRARY_PATH
        exec chroot "$ROOTFS" /system/bin/sh -c 'export PATH=/system/bin:/system/xbin ANDROID_ROOT=/system ANDROID_DATA=/data; exec "$@"' android-command "$@"
        ;;
    recover)
        root_required
        running && fail 'Android läuft noch. Erst stop verwenden.'
        orphan_active && fail 'Verwaiste Android-Prozesse noch aktiv. Keine Mounts entfernt; Kobo sauber neu starten.'
        # Never kill arbitrary PIDs or lazy-unmount potentially active filesystems.
        unmount_tree || fail 'Mounts belegt. Gerät sauber neu starten.'
        rm -f "$RUN/runner.pid" "$RUN/container.pid" "$RUN/vnc.pid" "$RUN/ready"
        rmdir "$RUN/lock" 2>/dev/null || true
        echo 'Laufzeitzustand bereinigt.'
        ;;
    *) echo 'Aufruf: sh android.sh {check|stages|start|stop|status|exec BEFEHL...|recover}' >&2; exit 2 ;;
esac
