# Vorgefertigte Android-Quellen und Anpassungen

Die schnelle Pipeline kompiliert **nicht** den vollständigen AOSP-Quellbaum. Sie lädt das offizielle Android-SDK-Systemimage `sysimg_armv7a-19_r03.zip` direkt von Google. Es ist Android 4.4.4/API 19, `armeabi-v7a`, SDK-Build 1743154. Die SHA-256-Prüfsumme ist `c1d4d7f49348ffc845e82267006d308e0a50e19411f27e00b894886b4e131627`. Das Archiv enthält eine ext4-Systempartition, eine Emulator-Ramdisk und einen QEMU-Kernel; der QEMU-Kernel wird nicht in das Kobo-Paket übernommen.

Die Pipeline übernimmt `/system` mit erhaltenen Eigentümern, Modi, Symlinks und Dateisystemrechten aus dem ext4-Image. Aus der Ramdisk werden init, Properties und der generierte `BOOTCLASSPATH` übernommen. Die Standard-Emulator-Init-Konfiguration wird durch die isolierte Kobo-Init ersetzt. Emulator-EGL/GLES-Emulationsbibliotheken werden entfernt und Software-EGL aktiviert. Geräte-Properties und kleine Dalvik-Heaps werden auf den experimentellen Kobo-Chroot angepasst.

Die kleine native Anpassung wird mit dem offiziellen Android-NDK r10e für Android API 19 gebaut, URL `https://dl.google.com/android/repository/android-ndk-r10e-linux-x86_64.zip`, SHA-256 `ee5f405f3b57c4f5c3b3b8b5d495ae12b660e03d2112e4ed5c728d349f1e520c`. Es entstehen die Bionic-Framebuffer-Preloadbibliothek `libkobofb.so` sowie statische ARM32-Helfer `kobo-vnc` und `kobo-container`. Der CI-Pfad braucht kein `repo sync`, keinen AOSP-Container und keinen Android-Vollbuild.

## Wichtige Hardwaregrenze

Das heruntergeladene Image ist ausdrücklich ein **ARM-Emulator-Systemimage**, kein Kobo-Produktimage. Es liefert Android 4.4.4 Framework, Apps, Dalvik, Software-Gralloc und Hinweise. Es enthält keinen Kobo-Kernel und keinen passenden Hersteller-HAL. Die Paketierung führt zu einem prüfbaren, schnellen Portierungsversuch, nicht zu einem nachgewiesenen Boot. Android muss auf dem Zielkernel mindestens mit Binder/Ashmem, Namespaces, Loop/ext4 und Software-Gralloc zusammenarbeiten. Der Kobo-Touchscreen, E-Ink-Refresh und echtes SurfaceFlinger-Rendering sind nicht durch CI-Tests belegt.

Aktuelle Android-GSIs sind keine direkte Alternative: Google beschreibt Treble-, Bootloader- und Mindestversionsvoraussetzungen für Geräte, auf denen GSIs geflasht werden. Dieser Workflow flasht überhaupt nichts; er startet einen älteren SDK-Userspace im vorhandenen Kobo-Linux-Chroot.

## Workflow und Artefakte

Der Workflow heißt **Android 4.4.4 API-19 ARM image for Kobo (experimental)**. Pushes und Pull Requests führen nur Hosttests aus. Nur `workflow_dispatch` lädt die beiden fest gepinnten Archive, baut native Helfer, erstellt das Rootfs und erzeugt das Paket. Das Joblimit ist 45 Minuten; eine erfolgreiche Ausführung sollte erheblich kürzer als ein Vollbuild sein, ist aber noch nicht in GitHub Actions gemessen.

Das Artefakt `kobo-android-kitkat-arm32-experimental` enthält `android-kobo.zip` und die alternative `kobo-android-kitkat.tar.gz`, jeweils mit Prüfsummen. `android-build-provenance-and-logs` enthält Downloadsummen, Build-Modus und Logs, auch im Fehlerfall. Das ext4-Rootfs erhält Android-Dateirechte und Symlinks, die FAT32-Onboard-Speicher sonst nicht bewahren kann.

## Quellen

[1]: https://dl.google.com/android/repository/sys-img/android/sysimg_armv7a-19_r03.zip "Offizielles Android-4.4.4-ARMv7a-SDK-Systemimage"
[2]: https://dl.google.com/android/repository/android-ndk-r10e-linux-x86_64.zip "Offizielles Android-NDK r10e für Linux x86-64"
[3]: https://developer.android.com/studio/run/managing-avds "Android-Entwicklerdokumentation zu Emulator-Systemimages und AVDs"
[4]: https://developer.android.com/topic/generic-system-image "Offizielle Android-GSI-Kompatibilitätsvoraussetzungen"
[5]: https://source.android.com/docs/setup/start/older-versions "Historische AOSP-Hostanforderungen für Android 2.3 bis 8.0"
