# Prüfstand des ausgelieferten Quellcodes

Stand: 2. November 2026. **Der vollständige AOSP-Build auf GitHub Actions und ein Android-Boot auf einem Kobo Libra Colour wurden nicht ausgeführt.** Es liegt ein implementiertes und hostgetestetes Portierungsprojekt vor, keine auf Kobo-Hardware als betriebsbereit bestätigte Firmware.

## Erfolgreich ausgeführt

Die gemeinsame Hosttestsuite bestand **36 Python-Tests**. Zusätzlich bestanden **12 Lua-RFB-Assertions**, die LuaJIT-Bytecodeprüfung sämtlicher Lua-Dateien, die Shell-Syntaxprüfung sämtlicher Starter und Buildskripte sowie `shellcheck -S warning` ohne verbleibende Warnungen. Workflow-YAML, Trigger, unveränderlicher Hash-Pin der Runner-Disk-Action, deren Start vor Checkout, die 40-GiB-Vorprüfung, Testabhängigkeit und das 350-Minuten-Limit wurden geprüft. Zwei manuelle GitHub-Läufe haben die LVM-Action tatsächlich ausgeführt, aber nur 36,4 GiB frei bereitgestellt und brachen vor dem AOSP-Sync ab. Die Logs zeigten, dass `/mnt` kein separates Dateisystem ist und ein inaktives 3-GiB-`/swapfile` auf `/` liegenblieb, weil die Action nur `/mnt/swapfile` entfernte. Das zusätzliche Entfernen dieses Swapfiles und der 1-GiB-LVM-Swap wurden noch nicht auf GitHub gemessen.

Elf native Integrationstests kompilieren und starten die echten C-Komponenten. Sie prüfen Framebuffer-ioctls, Shared-Memory-Pixel, Deskriptor-Duplikation, Metadaten, Seitenwechsel, RGB565-/RGB888-Konvertierung, Endianness, geänderte Zeilen, inkrementelle Updates, fehlerhafte RFB-Clients, Wiederverbinden und Transfer-Timeouts. Für Hosttests wird Eingabe ausdrücklich mit `--no-input` deaktiviert; das ist kein Ersatz für einen uinput-Gerätetest.

Die Installer-Tests prüfen Prüfsummen, atomare Dekomprimierung, beschädigte Archive, Größenabweichungen und den Schutz eines vorhandenen Daten-Images. Eine zusätzliche Integrationsregression prüft, dass Rootfs-Erzeuger, Shellstarter und PID-Namespace-Helfer denselben Sicherheitsmarker `/kobo-chroot` verwenden. Eine 4-GiB-Datei, die FAT32 nicht speichern kann, wird bereits vor dem Imagebau abgewiesen.

Build-/Pakettests verwenden ausdrücklich **Fixtures**, keine vollständig gebauten Android-Dateien. Sie prüfen Patch-Idempotenz, Abbruch bei unbekannten Quellständen, erhaltene Bootstrap-Aktionen, global deaktiviertes GLES2-HWUI, ext4-/ELF-Merkmale, statische ARM-Helfer, Pluginpfade, Paketstruktur und Prüfsummen. Diese Tests beweisen nicht, dass der gesamte alte Android-Quellbaum kompiliert.

Die fünf hash-geprüften AOSP-Patches wurden außerdem auf die tatsächlich heruntergeladenen Originaldateien von `android-4.4.4_r2` angewandt und erneut idempotent ausgeführt. Eine separate ext4-Rauchprüfung mit einem 384-MiB-Test-Dateisystem bestand `e2fsck`; numerische Eigentümer, Dateimodi und ein Symlink blieben erhalten. Das war ein Dateisystemtest, kein Android-Rootfs-Boot.

Der Container-Starter wurde mit strikten GCC-Warnungen kompiliert. Seine tatsächliche Mount-/PID-Namespace-Vorprüfung bestand auf dem Entwicklungs-Host. Native Shim-/Server-Tests liefen auf **AArch64 Linux mit glibc**. Die KitKat-Bionic-Header wurden gezielt auf die verwendeten Schnittstellen geprüft; ein ARM32-Bionic-Compiler-/Linkerlauf wurde lokal nicht durchgeführt.

Reproduzierbare Hauptbefehle:

```sh
python3 -m unittest discover -s tests -p 'test_*.py' -v
luajit tests/test_lua.lua
shellcheck -S warning runtime/*.sh scripts/*.sh
```

## Noch nicht nachgewiesen

Die Ubuntu-14.04-/OpenJDK-7-Kompatibilitätsumgebung muss den vollständigen AOSP-Build in CI noch erfolgreich abschließen. Ebenso unbestätigt sind die neue Speicherkapazität nach Swap-Bereinigung und die Laufzeit eines konkreten GitHub-Runners, die resultierenden ARM32-Bionic-Binärdateien und der erste Android-Framework-Boot. Die gepinnte Drittanbieter-LVM-Action ist nicht von GitHub unterstützt und kann durch Runner-Änderungen ausfallen.

Auf dem Kobo müssen insbesondere Binder-Protokoll 7, Ashmem, uinput-Geräteerzeugung und Event-Erkennung, PID-/Mount-Namespaces, Loop/ext4, Software-Gralloc, SurfaceFlinger, Systemserver sowie Touch und E-Ink-Darstellung geprüft werden. `sh android.sh check` prüft Kernelvoraussetzungen, ersetzt jedoch keinen Bootnachweis. Für den Framework-Boot muss `sh android.sh exec getprop sys.boot_completed` schließlich `1` ausgeben.

Es wurden keine vorhandenen Kobo-Daten verändert, keine Firmwarepartitionen beschrieben und keine Kernelmodule nachgeladen. Reale RAM-Werte, Akkulaufzeit, Suspend-Verhalten, allgemeine APK-Kompatibilität und langfristige Dateisystemstabilität sind nicht gemessen.
