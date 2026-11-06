# KitKat-API-19-Chroot: Prüfstand

## Auswertung der Kobo-Logs

Die bereitgestellten Logs enthalten den Rootfs-Marker `android-5.0.2_api21`; sie stammen damit von einem Lollipop/API-21-Rootfs und **nicht** von dem hier gewünschten KitKat/API-19-Build. Die Logs dokumentieren dennoch konkrete Fehler im gemeinsamen Startpfad:

- `logcat` zeigt `BatteryService.<init>` mit `NullPointerException` und anschließend `BOOT FAILURE making display ready`. `healthd.txt` meldet `Service batteryproperties: not found`; `bootwatch.log` zeigt `healthd=restarting`. Das belegt, dass der Akku-Properties-Binder-Dienst nicht verfügbar war.
- `logcat` enthält wiederholt `logwrapper: Cannot create parent ptty`. Die angepasste Init hatte `/dev/pts` erzeugt, aber nicht `devpts` gemountet. Netd-/iptables-Aufrufe scheiterten ebenfalls.
- `stages.log` zeigt zusätzlich einen Segfault beim direkten `/system/bin/sh`-Probe. Der spätere normale Start lief aber deutlich weiter bis Zygote und SystemServer; der Probe-Fehler darf daher nicht mit dem dokumentierten Framework-Bootfehler gleichgesetzt werden.

## Ursache der Bootschleife (Nachtrag)

`/sbin/healthd` ist in KitKat **statisch** gelinkt. `LD_PRELOAD=libkobofb.so` (Binder-32→64-Bit-Übersetzung) wirkt auf statische Programme nicht. Der Kobo-Kernel 4.9.77 spricht Binder-Protokoll 8 (64 Bit); healthd scheitert bei `BINDER_VERSION` und beendet sich, `batteryproperties` wird nie registriert, `BatteryService.<init>` wirft die NPE, system_server stirbt, zygote startet endlos neu. Die QEMU-Variante hat einen Kernel mit `CONFIG_ANDROID_BINDER_IPC_32BIT` und braucht keine Übersetzung. Die Reihenfolge-/Trigger-Änderungen unten beseitigen diese Ursache nicht. Fix: `native/kobo_healthd.c` (dynamisch, bionic) ersetzt `/sbin/healthd`, registriert `batteryproperties` und meldet einen festen Akkustand. Auf Gerät noch nicht verifiziert (Log: `/data/local/tmp/kobo-healthd.log`).

## Umgesetzte Änderungen

1. Der erste veröffentlichte Fix schob `healthd` hinter `servicemanager`; das wich von QEMUs erfolgreicher Reihenfolge ab. Der aktuelle Init startet `healthd` wieder als `core`-Dienst vor `servicemanager`.
2. Der QEMU-Vergleich deckte eine fehlende Boot-Eventkette auf: `on fs` setzt nun `ro.crypto.state=unencrypted` und triggert `nonencrypted`; dieser Event startet `late_start`. `post-fs-data` setzt wie QEMU `vold.post_fs_data_done=1`.
3. `devpts` bleibt für die in den Kobo-Logs sichtbaren PTY-Fehler eingebunden. Der Build ist auf Android KitKat/API 19 festgelegt; das SDK-Archiv ist mit SHA-256 `ca7440cade53d829a8cace857cfad9afaa174c286d1b7a5d139e73cfcfde45d7` gepinnt.

## Verifikation und offene Punkte

Nach Ergänzung der QEMU-Eventkette laufen **42 Hosttests: 38 erfolgreich, 4 übersprungen**; Bash-Syntax, ShellCheck und `git diff --check` sind sauber. Der vollständige API-19-Build war in der ARM64-Sandbox beim x86-64-Compiler des NDK r10e blockiert.

Der aktuelle Satz Kobo-Logs stammt laut Rootfs-Marker von API 21 und kann die KitKat-Änderungen nicht validieren. Ein echter Libra-Colour-Boot mit API 19 ist ebenfalls noch nicht nachgewiesen. Nach Aktualisierung muss auf dem Gerät `getprop sys.boot_completed` schließlich `1` liefern; außerdem müssen `batteryproperties` im ServiceManager erscheinen und die PTY-/iptables-Fehler verschwinden.

Hosttests starten Android nicht und beweisen keinen Geräteboot. Kein Firmware- oder Kernelimage wird geschrieben. Die zusätzlichen Init-Mounts liegen unter dem Android-Rootfs, sollten aber wegen des auf älteren Kobo-Kerneln verwendeten, weniger isolierten Chroot-Fallbacks auf dem Zielgerät kontrolliert geprüft werden.
