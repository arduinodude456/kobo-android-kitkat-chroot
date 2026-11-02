# Prüfstand des experimentellen Prebuilt-Builds

Stand: 2. November 2026. Der CI-Pfad wurde von einem vollständigen AOSP-Quellbuild auf ein verifiziertes Android-4.4.4-ARM-Emulator-Systemimage umgestellt. **Die neue GitHub-Actions-Pipeline wurde noch nicht ausgeführt und ein echter Libra Colour stand nicht zum Testen zur Verfügung.** Das Ergebnis bleibt ein experimenteller Chroot-Portierungsversuch.

## Bereits geprüft

Das offizielle Google-SDK-Archiv `sysimg_armv7a-19_r03.zip` wurde heruntergeladen. Seine SHA-256-Prüfsumme stimmt mit `c1d4d7f49348ffc845e82267006d308e0a50e19411f27e00b894886b4e131627` überein. Das Image enthält Android 4.4.4/API 19 ARM EABI v7a, ext4 `/system`, Ramdisk, Emulator-Kernel und Android-Apps. Die nötigen Framework-Apps, Software-GLES, Default-Gralloc und Android-Notice-Datei wurden in der Partition gefunden. Der Emulator-Kernel wird nicht übernommen; die EGL-Konfiguration und Emulator-Emulationsbibliotheken werden angepasst.

Das offizielle Android-NDK r10e wurde heruntergeladen. Die SHA-256-Prüfsumme ist `ee5f405f3b57c4f5c3b3b8b5d495ae12b660e03d2112e4ed5c728d349f1e520c`. Der Compiler kann in dieser ARM64-Entwicklungsumgebung nicht ausgeführt werden, da das historische NDK ausschließlich einen x86-64-Hostcompiler enthält. GitHub `ubuntu-24.04` ist x86-64; die eigentliche Bionic-Kompilierung muss dort im ersten CI-Lauf verifiziert werden.

Vor der Umstellung bestanden 36 Python-Tests und 12 Lua-RFB-Assertions. Diese Tests prüfen Host-Laufzeit, Paketierung und Fixtures; sie beweisen nicht den Android-Boot. Die neu hinzugefügten Workflowtests prüfen, dass der manuelle Job nur die fest gepinnten SDK-/NDK-Downloads und Native-Builds verwendet und keinen `repo sync`, AOSP-Vollbuild oder LVM-Disk-Workaround mehr startet.

## Noch offen

Der neue Workflow muss auf GitHub erfolgreich ARM32-Bionic-Helper kompilieren, die Systempartition und Ramdisk übernehmen, ein ext4-Rootfs bilden und das ZIP hochladen. Erst danach wissen wir, ob das Paketierungsformat mit diesem SDK-Image konsistent ist. Eine CI-Erzeugung bestätigt noch nicht, dass Android auf echter Kobo-Firmware startet.

Auf dem Gerät sind insbesondere Binder/Ashmem, Namespaces, Loop/ext4, Bionic-Prozessstart, Framebuffer-Preload, Software-Gralloc, SurfaceFlinger, Systemserver, Touch und E-Ink-Darstellung zu testen. Der SDK-Build ist ein Emulator-Image, kein Kobo-ROM und enthält keine herstellerspezifischen Kobo-HALs. `sh android.sh check` prüft Voraussetzungen; für einen erfolgreichen Framework-Boot muss `sh android.sh exec getprop sys.boot_completed` schließlich `1` ausgeben.

Keine Kobo-Daten wurden verändert, keine Firmwarepartition beschrieben und keine Kernelmodule geladen. RAM-Werte, Laufzeit auf dem Gerät, Akkulaufzeit, Suspend-Verhalten und APK-Kompatibilität sind nicht gemessen.
