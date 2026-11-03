# Prüfstand des experimentellen Prebuilt-Builds

Stand: 2. November 2026. Der CI-Pfad wurde von einem vollständigen AOSP-Quellbuild auf ein verifiziertes Android-5.0.2-ARM-Emulator-Systemimage umgestellt. **Die neue GitHub-Actions-Pipeline wurde noch nicht ausgeführt und ein echter Libra Colour stand nicht zum Testen zur Verfügung.** Das Ergebnis bleibt ein experimenteller Chroot-Portierungsversuch.

## Bereits geprüft

Das offizielle Google-SDK-Archiv `armeabi-v7a-21_r04.zip` wurde heruntergeladen. Seine SHA-256-Prüfsumme stimmt mit `4f20bb4abff1fcda7fdde510993d2004b0ca330ae6e7a798ffecc3fbf6d48520` überein. Das Image enthält Android 5.0.2/API 21 ARM EABI v7a, ext4 `/system`, Ramdisk, Emulator-Kernel und Android-Apps. Die nötigen Framework-Apps, Software-GLES, Default-Gralloc und Android-Notice-Datei wurden in der Partition gefunden. Der Emulator-Kernel wird nicht übernommen; die EGL-Konfiguration und Emulator-Emulationsbibliotheken werden angepasst.

Das offizielle Android-NDK r10e wurde heruntergeladen. Die SHA-256-Prüfsumme ist `ee5f405f3b57c4f5c3b3b8b5d495ae12b660e03d2112e4ed5c728d349f1e520c`. Der Compiler kann in dieser ARM64-Entwicklungsumgebung nicht ausgeführt werden, da das historische NDK ausschließlich einen x86-64-Hostcompiler enthält. GitHub `ubuntu-24.04` ist x86-64; die eigentliche Bionic-Kompilierung muss dort im ersten CI-Lauf verifiziert werden.

Vor der Umstellung bestanden 36 Python-Tests und 12 Lua-RFB-Assertions. Diese Tests prüfen Host-Laufzeit, Paketierung und Fixtures; sie beweisen nicht den Android-Boot. Die neu hinzugefügten Workflowtests prüfen, dass der manuelle Job nur die fest gepinnten SDK-/NDK-Downloads und Native-Builds verwendet und keinen `repo sync`, AOSP-Vollbuild oder LVM-Disk-Workaround mehr startet.

## Binder-Shim (2. November 2026)

`native/kobo_binder.c` ist gegen die echte uapi-Header-Datei (beide Konfigurationen, `tests/binder_abi_check_*.c`) und gegen einen simulierten 64-Bit-Binder-Kernel (`tests/binder_shim_test.c`, ARM32 unter qemu-user) geprüft: Transaktionen mit Objekten in beide Richtungen, Reply, Status-Codes, Death-Notifications, Teilverbrauch des Schreibstroms, Fehlerpfade, Speicherfreigabe. Gegen einen echten Binder-Treiber, Bionic-libbinder oder auf dem Gerät wurde er **nicht** ausgeführt. Mögliche weitere Blocker nach dem Binder: SELinux-`load_policy` des Stock-init, SurfaceFlinger/Gralloc, Zygote-Speicherbedarf.

## Noch offen

Der neue Workflow muss auf GitHub erfolgreich ARM32-Bionic-Helper kompilieren, die Systempartition und Ramdisk übernehmen, ein ext4-Rootfs bilden und das ZIP hochladen. Erst danach wissen wir, ob das Paketierungsformat mit diesem SDK-Image konsistent ist. Eine CI-Erzeugung bestätigt noch nicht, dass Android auf echter Kobo-Firmware startet.

Auf dem Gerät sind insbesondere Binder/Ashmem, Namespaces, Loop/ext4, Bionic-Prozessstart, Framebuffer-Preload, Software-Gralloc, SurfaceFlinger, Systemserver, Touch und E-Ink-Darstellung zu testen. Der SDK-Build ist ein Emulator-Image, kein Kobo-ROM und enthält keine herstellerspezifischen Kobo-HALs. `sh android.sh check` prüft Voraussetzungen; für einen erfolgreichen Framework-Boot muss `sh android.sh exec getprop sys.boot_completed` schließlich `1` ausgeben.

Keine Kobo-Daten wurden verändert, keine Firmwarepartition beschrieben und keine Kernelmodule geladen. RAM-Werte, Laufzeit auf dem Gerät, Akkulaufzeit, Suspend-Verhalten und APK-Kompatibilität sind nicht gemessen.
