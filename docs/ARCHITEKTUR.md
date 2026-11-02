# Architektur und Grenzen

Dieses Projekt erzeugt ein eigenes AOSP-Android-4.4.4-ARM32-Userspace für einen Chroot. Es erzeugt **keine startfähige Kobo-Ersatzfirmware**, keinen Kernel und kein Flash-Image. Der vorhandene Kobo-Linux-Kernel bleibt aktiv. Damit werden weder Bootloader noch Secure Boot verändert. Für den Libra Colour sind signierte Bootloader-/Kernel-Images dokumentiert; ein Userspace-Projekt kann diese Grenze nicht durch einen Framebuffer-Shim aufheben. [1]

## Bild und Eingabe

Android verwendet den generischen Software-Grafikpfad. Der Bionic-`LD_PRELOAD`-Shim `libkobofb.so` bildet die Framebuffer-Dateioperationen auf einen kleinen gemeinsamen Speicherbereich ab. Die Standardauflösung beträgt 600 × 800 Pixel mit RGB565 und zwei Bildseiten. Diese beiden Bildseiten benötigen zusammen 1.920.000 Byte; zusätzliche VNC-, KOReader-, App- und Framework-Puffer kommen hinzu. Das ist **keine Aussage über den gesamten Android-RAM-Verbrauch**.

Der generische Android-4.4-Gralloc-Treiber öffnet `/dev/graphics/fb0` beziehungsweise `/dev/fb0`, fragt die Linux-Framebuffer-Informationen per `ioctl` ab und mappt den Speicher. Der Shim bedient diesen Vertrag. Ein bloßes Kopieren von Screenshots würde dafür nicht ausreichen. [2]

`kobo-vnc` läuft außerhalb des Android-PID-Namespace. Es beobachtet die gemeinsame Bilddatei, stellt RFB 3.8 ausschließlich auf `127.0.0.1:5963` bereit und wandelt RFB-Eingaben in eigene `uinput`-Geräte um. Nur die zugehörigen Event-Geräte werden im Android-`/dev/input` angelegt. Android erhält weder das echte Kobo-Framebuffer-Gerät noch die echten Kobo-Touch-/Seitentasten-Eventgeräte. Die KOReader-Lua-Ansicht übernimmt E-Ink-Refresh, Touch, Wischen und die Navigationsschaltflächen.

Der lokale VNC-Endpunkt verwendet keine Authentifizierung. Das ist nur wegen der festen Loopback-Bindung vertretbar. Andere lokale Prozesse auf dem Kobo können sich trotzdem verbinden. Es wird kein Port für WLAN-Clients geöffnet.

## Prozess- und Dateisystemgrenzen

`android.sh` mountet ausschließlich unter seinem eigenen `run/`-Verzeichnis: das ext4-Image und kleine temporäre Dateisysteme für Geräte und Bilddaten. `kobo-container` fordert einen privaten Mount- und PID-Namespace an. Erst dessen Kindprozess mit PID 1 darf das eigens angepasste Android-`/init` starten. Ein Fehler beim Erzeugen der Namespaces führt zum Abbruch, nicht zum Start von Android-init im Kobo-Hostsystem.

Die frühe Android-init-Mount-/SELinux-Sequenz wird für dieses spezielle Produkt angepasst. Sie darf insbesondere keine Host-SELinux-Policy laden und keine Host-`/dev`-, `/proc`- oder `/sys`-Mounts verändern. Die Property-Infrastruktur und die Verwaltung der Android-Dienste bleiben erhalten. Die Originalquelle des KitKat-init ist die Grundlage dieses gezielten Patches. [3]

Die Aufteilung ist keine Sicherheitsgrenze für bösartige Root-Prozesse: Es gibt weder einen eigenen Kernel noch vollständige Capability-, Netzwerk- oder Binder-Isolation. Android nutzt den Host-Netzwerkstack. Kein Play Store, keine Google-Dienste und keine moderne TLS-/Web-Kompatibilität werden zugesichert. KitKat ist veraltet; nur offline und mit vertrauenswürdigen APKs experimentieren.

## Unverzichtbare Kernelvoraussetzungen

Die Vorprüfung verlangt einen für KitKat kompatiblen Binder-Treiber, Ashmem, `uinput`, PID-/Mount-Namespaces, Loop-Geräte und ext4. Binder ist die Android-Kommunikationsgrundlage und beinhaltet einen Kernel-Treiber. Ein Userspace-Shim ersetzt ihn nicht. [4]

Fehlende `/dev/binder`- oder `/dev/ashmem`-Nodes können auf fehlende Treiber oder lediglich fehlende Nodes hinweisen. Das Projekt rät keine Major-/Minor-Nummern und lädt keine beliebigen Kernelmodule. Ohne einen nachweislich passenden Treiber ist das Gerät nicht freigegeben. Moderne Binder-Protokollvarianten sind nicht automatisch mit dem alten ARM32-Userspace kompatibel; die Vorprüfung prüft die erwartete ABI.

Dass das Gerät ARM32-Code ausführen kann, beweist nicht, dass alle Android-Kerneloptionen vorhanden sind. Die konkrete Kobo-Firmware muss daher auf dem Gerät geprüft werden. Ein bestandener Vorabtest beweist wiederum noch keinen vollständigen Android-Boot.

## Start, Stopp und Speicherung

Ein ext4-Image ist nötig, weil das Kobo-Onboard-Dateisystem Unix-Symlinks, Eigentümer und Dateimodi nicht zuverlässig wie Android benötigt abbildet. Nur das große Image und die Starter liegen direkt auf dem Onboard-Dateisystem. Die Installer-Prüfsumme schützt vor beschädigter Übertragung, ist aber keine Signatur gegen einen manipulierten Download.

Beim regulären Beenden werden wichtige Android-Schreiber gestoppt und Dateisystemdaten synchronisiert. Danach wird ausschließlich der private PID-Namespace beendet. Belegte Mounts werden nicht mit `umount -l` erzwungen. Nach einem Stromausfall kann eine ext4-Prüfung nötig sein. Während Android läuft, den Kobo nicht per USB als Datenträger am PC verwenden und das Image nicht verschieben oder ersetzen.

## References

[1]: https://www.mobileread.com/forums/showthread.php?t=363175 "Kobo Libra Colour is using Secure Boot – technische Boot-Logs und Diskussion"
[2]: https://android.googlesource.com/platform/hardware/libhardware/+/android-4.4.4_r2/modules/gralloc/framebuffer.cpp "AOSP KitKat: generischer Framebuffer-Gralloc-Treiber"
[3]: https://android.googlesource.com/platform/system/core/+/android-4.4.4_r2/init/init.c "AOSP KitKat: init und Property-Infrastruktur"
[4]: https://source.android.com/docs/core/architecture/ipc/binder-overview "AOSP: Binder-Architektur und Kernel-Treiber"
