# Architektur und Grenzen

Dieses Projekt passt ein vorgefertigtes generisches Android-KitKat 4.4-ARM32-SDK-Emulator-Userspace für einen Chroot an. Es erzeugt **keine startfähige Kobo-Ersatzfirmware**, keinen Kernel und kein Flash-Image. Der vorhandene Kobo-Linux-Kernel bleibt aktiv. Damit werden weder Bootloader noch Secure Boot verändert. Für den Libra Colour sind signierte Bootloader-/Kernel-Images dokumentiert; ein Userspace-Projekt kann diese Grenze nicht durch einen Framebuffer-Shim aufheben. [1]

## Bild und Eingabe

Android verwendet den generischen Software-Grafikpfad. Der Bionic-`LD_PRELOAD`-Shim `libkobofb.so` bildet die Framebuffer-Dateioperationen auf einen kleinen gemeinsamen Speicherbereich ab. Die Standardauflösung beträgt 600 × 800 Pixel mit RGB565 und zwei Bildseiten. Diese beiden Bildseiten benötigen zusammen 1.920.000 Byte; zusätzliche VNC-, KOReader-, App- und Framework-Puffer kommen hinzu. Das ist **keine Aussage über den gesamten Android-RAM-Verbrauch**.

Der generische Android-KitKat-4.4-Gralloc-Treiber öffnet `/dev/graphics/fb0` beziehungsweise `/dev/fb0`, fragt die Linux-Framebuffer-Informationen per `ioctl` ab und mappt den Speicher. Der Shim bedient diesen Vertrag. Ein bloßes Kopieren von Screenshots würde dafür nicht ausreichen. [2]

`kobo-vnc` läuft außerhalb des Android-PID-Namespace. Es beobachtet die gemeinsame Bilddatei, stellt RFB 3.8 ausschließlich auf `127.0.0.1:5963` bereit und wandelt RFB-Eingaben in eigene `uinput`-Geräte um. Nur die zugehörigen Event-Geräte werden im Android-`/dev/input` angelegt. Android erhält weder das echte Kobo-Framebuffer-Gerät noch die echten Kobo-Touch-/Seitentasten-Eventgeräte. Die KOReader-Lua-Ansicht übernimmt E-Ink-Refresh, Touch, Wischen und die Navigationsschaltflächen.

Der lokale VNC-Endpunkt verwendet keine Authentifizierung. Das ist nur wegen der festen Loopback-Bindung vertretbar. Andere lokale Prozesse auf dem Kobo können sich trotzdem verbinden. Es wird kein Port für WLAN-Clients geöffnet.

## Prozess- und Dateisystemgrenzen

`android.sh` mountet zunächst unter seinem eigenen `run/`-Verzeichnis: das ext4-Image und kleine temporäre Dateisysteme für Geräte und Bilddaten. `kobo-container` verwendet private Mount- und PID-Namespaces, wenn der Kernel sie anbietet. Auf älteren Kobo-Kerneln ist standardmäßig ein weniger isolierter Chroot-Fallback aktiviert; dann teilen Android und der Host Mount- und PID-Namespace. Dieser Fallback ist absichtlich kein Sicherheitsboundary und kann bei Abstürzen oder fehlerhaften Mounts den Kobo-Host beeinflussen.

Die Emulator-Ramdisk wird übernommen, ihre generische Emulator-`init.rc` aber durch die kleine isolierte Kobo-Init-Konfiguration ersetzt. Sie darf insbesondere keine Host-SELinux-Policy laden und keine Host-`/dev`-, `/proc`- oder `/sys`-Mounts verändern. Die Property-Infrastruktur und die Verwaltung der Android-Dienste bleiben erhalten. Ein echter Start unter dem Kobo-Kernel muss noch auf Hardware nachgewiesen werden. [3]

Die Aufteilung ist keine Sicherheitsgrenze für bösartige Root-Prozesse: Es gibt weder einen eigenen Kernel noch vollständige Capability-, Netzwerk- oder Binder-Isolation. Android nutzt den Host-Netzwerkstack. Kein Play Store, keine Google-Dienste und keine moderne TLS-/Web-Kompatibilität werden zugesichert. KitKat ist veraltet; nur offline und mit vertrauenswürdigen APKs experimentieren.

## Unverzichtbare Kernelvoraussetzungen

Die Vorprüfung verlangt einen für KitKat kompatiblen Binder-Treiber, Ashmem, `uinput`, Loop-Geräte und ext4. PID-/Mount-Namespaces werden verwendet, wenn vorhanden; ohne sie greift der standardmäßige weniger isolierte Chroot-Fallback. Binder ist die Android-Kommunikationsgrundlage und beinhaltet einen Kernel-Treiber. Ein Userspace-Shim ersetzt ihn nicht. [4]

Fehlende `/dev/binder`- oder `/dev/ashmem`-Nodes können auf fehlende Treiber oder lediglich fehlende Nodes hinweisen. Das Projekt rät keine Major-/Minor-Nummern und lädt keine beliebigen Kernelmodule. Ohne einen nachweislich passenden Treiber ist das Gerät nicht freigegeben. Der Kobo-Kernel 4.9.77 ist ohne `CONFIG_ANDROID_BINDER_IPC_32BIT` gebaut und spricht Binder-Protokoll 8 mit 64-Bit-Strukturen, KitKat/API 19 spricht Protokoll 7 mit 32-Bit-Strukturen (`BINDER_WRITE_READ` 24 statt 48 Byte, `0xc0186201` statt `0xc0306201`). Deshalb übersetzt `libkobofb.so` (`native/kobo_binder.c`, per `LD_PRELOAD` in jedem Android-Prozess) `BINDER_VERSION` und `BINDER_WRITE_READ`: Befehlsströme in beide Richtungen, Transaktionsdaten samt `flat_binder_object` (16 ↔ 24 Byte) und Offsets-Array (u32 ↔ u64), und die vom Treiber read-only gemappten Empfangspuffer (Kopie mit Rückabbildung bei `BC_FREE_BUFFER`). Alle anderen Binder-ioctls sind in beiden ABIs identisch. Grenzen: nur 32-Bit-Prozesse, keine Scatter-Gather-Objekte (`BINDER_TYPE_PTR`/`FDA`), Lese-Puffer mindestens 68 Byte. Mit `KOBO_BINDER_LOG` (Standard `/data/local/tmp/kobo-binder.log` im Rootfs) schreibt der Shim je Prozess eine Startzeile und Übersetzungsfehler; der Log-Button des Plugins zeigt sie an.

Dass das Gerät ARM32-Code ausführen kann, beweist nicht, dass alle Android-Kerneloptionen vorhanden sind. Die konkrete Kobo-Firmware muss daher auf dem Gerät geprüft werden. Ein bestandener Vorabtest beweist wiederum noch keinen vollständigen Android-Boot.

## Start, Stopp und Speicherung

Ein ext4-Image ist nötig, weil das Kobo-Onboard-Dateisystem Unix-Symlinks, Eigentümer und Dateimodi nicht zuverlässig wie Android benötigt abbildet. Nur das große Image und die Starter liegen direkt auf dem Onboard-Dateisystem. Die Installer-Prüfsumme schützt vor beschädigter Übertragung, ist aber keine Signatur gegen einen manipulierten Download.

Beim regulären Beenden werden wichtige Android-Schreiber gestoppt und Dateisystemdaten synchronisiert. Danach wird ausschließlich der private PID-Namespace beendet. Belegte Mounts werden nicht mit `umount -l` erzwungen. Nach einem Stromausfall kann eine ext4-Prüfung nötig sein. Während Android läuft, den Kobo nicht per USB als Datenträger am PC verwenden und das Image nicht verschieben oder ersetzen.

## References

[1]: https://www.mobileread.com/forums/showthread.php?t=363175 "Kobo Libra Colour is using Secure Boot – technische Boot-Logs und Diskussion"
[2]: https://android.googlesource.com/platform/hardware/libhardware/+/android-4.4.4_r2/modules/gralloc/framebuffer.cpp "AOSP KitKat: generischer Framebuffer-Gralloc-Treiber"
[3]: https://android.googlesource.com/platform/system/core/+/android-4.4.4_r2/init/init.c "AOSP KitKat: init und Property-Infrastruktur"
[4]: https://source.android.com/docs/core/architecture/ipc/binder-overview "AOSP: Binder-Architektur und Kernel-Treiber"
