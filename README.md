# Android 4.4.4 für Kobo Libra Colour – experimenteller Chroot

Dieses Repository paketiert eine vorgefertigte Android-4.4.4-ARMv7-Systempartition aus dem offiziellen Android-SDK für API 19. Actions lädt die Image-Datei und das kleine Android-NDK herunter, baut nur die Kobo-spezifischen nativen Helfer, passt Ramdisk und Properties an und erzeugt ein ext4-Rootfs mit KOReader-/AppDock-Anbindung. **Es gibt keinen AOSP-Vollbuild mehr.**

**Keine Kobo-Ersatzfirmware:** Das Paket startet Android als Chroot auf dem vorhandenen Kobo-Linux-Kernel. Es flasht keinen Kernel und keinen Bootloader. Das SDK-Image wurde für einen ARM-Android-Emulator gebaut, nicht für den Libra Colour. Ob Framework, Binder/Ashmem, Framebuffer-Shim und Oberfläche auf echter Kobo-Firmware zusammenlaufen, ist noch ungetestet. Ein erfolgreicher Actions-Build beweist deshalb noch keinen Android-Boot auf dem Gerät.

## Paket bauen und herunterladen

1. Stelle sicher, dass die Workflow-Datei unter `.github/workflows/build.yml` im Standardbranch liegt und GitHub Actions aktiviert ist.
2. Öffne im GitHub-Reiter **Actions** den Workflow **Android 4.4.4 API-19 ARM image for Kobo (experimental)** und wähle **Run workflow**. Pushes auf `main` und Pull Requests führen nur die schnellen Hosttests aus.
3. Nach einem erfolgreichen Lauf lade das Artefakt **kobo-android-kitkat-arm32-experimental** herunter. Darin liegt `android-kobo.zip` mit den eigentlichen `.adds/`-Installationsdateien; die `.tar.gz`-Datei enthält denselben Payload.

Der Build lädt ungefähr 1,2 GB an fest gepinnten SDK-/NDK-Archiven herunter und kompiliert nur drei kleine ARM-Binaries. Er sollte daher deutlich kürzer als der frühere AOSP-Quellbuild laufen; die tatsächliche Zeit hängt vom GitHub-Runner und Netzwerk ab. Beide Downloads werden vor Verwendung per SHA-256 geprüft. Diagnoselogs und Herkunftsnachweise werden zusätzlich als **android-build-provenance-and-logs** hochgeladen.

## Was das Paket enthält – und was nicht

Das Android-SDK-Archiv enthält ein generisches Android 4.4.4 API-19 ARM-EABI-v7a-Systemimage. Actions übernimmt dessen `/system`-Partition und Ramdisk, ersetzt die Emulator-Init-Konfiguration durch eine isolierte Kobo-Chroot-Konfiguration, setzt niedrige Dalvik-Heap-Limits und Software-EGL und entfernt Emulator-Grafikshim-Bibliotheken. Mit NDK r10e werden `libkobofb.so`, `kobo-vnc` und `kobo-container` gebaut. Danach werden Rootfs, Starter, KOReader-Plugin, Prüfsummen und Provenienz paketiert.

Das SDK-Systemimage enthält weiterhin generische Android-4.4.4-Frameworkdateien und Emulatorreste, die für den Chroot nicht ausgewählt werden sollen. Die Anpassung ist ein schneller Portierungsversuch, kein nachweislich Kobo-kompatibles ROM. Android-GSIs sind kein Ersatz: Googles aktuelle GSIs setzen ein entsperrtes, Treble-fähiges Gerät voraus, das mit Android 9 oder neuer ausgeliefert wurde. Der Libra Colour startet stattdessen Kobo-Linux und erhält Android hier nur als Chroot-Userspace.

## RAM-schonender Ansatz

Die Android-Anzeige bleibt bei 600 × 800 Pixeln und RGB565 mit zwei Bildseiten. Die VNC-Brücke benötigt keine externe VNC-Bibliothek. KOReader zeigt das Bild ohne zusätzliche Desktop-Umgebung an. Niedrige Dalvik-Heap-Limits, Low-RAM-Einstellungen, deaktivierte Animationen und eine reduzierte Grafik-Konfiguration sollen unnötige Last begrenzen.

Damit ist Android aber nicht auf wenige Megabyte reduziert: Zygote, Systemserver, SurfaceFlinger, notwendige Framework-Dienste und Apps benötigen weiterhin Speicher. Es gibt noch keinen auf dem Gerät gemessenen RAM-Wert und keine Garantie gegen Speicherknappheit bei parallel laufendem Nickel/KOReader. E-Ink begrenzt die wahrnehmbare Bildrate; schnelle Spiele und flüssiges Video sind kein Ziel.

## Auf dem Kobo starten

Das von Actions erzeugte Installationspaket entpacken und `.adds/` auf den Kobo kopieren. KOReader muss bereits installiert sein. Das Plugin ergänzt das Werkzeugmenü um **Android 4.4 (Chroot)**. Der erste Start prüft und entpackt das Rootfs. Das Image enthält danach auch persistente Android-App-Daten.

Manuell aus einer Kobo-Root-Shell:

```sh
cd /mnt/onboard/.adds/android
sh install.sh
sh android.sh check
sh android.sh start
sh android.sh exec getprop sys.boot_completed
sh android.sh stop
```

`sys.boot_completed` muss schließlich `1` ergeben. Ein offener VNC-Port oder sichtbares Bild allein ist kein vollständiger Bootnachweis. Vor USB-Datenträgermodus oder Firmware-Update Android unbedingt stoppen. Vollständige Installation, APK-Sideloading, Logs und Fehlerbehebung stehen in [docs/KOBO.md](docs/KOBO.md).

## Voraussetzungen und Sicherheit

Erforderlich sind Root-Rechte, ein KitKat-kompatibler Binder-Treiber, Ashmem, `uinput`, Loop-Geräte und ext4. Der Starter verwendet PID-/Mount-Namespaces, wenn der Kernel sie unterstützt. Auf älteren Kobo-Kerneln ist standardmäßig ein weniger isolierter Chroot-Fallback aktiv, damit Android überhaupt starten kann; dabei teilen Android und Kobo Mount- und PID-Namespace. Keine unpassenden Kernelmodule laden und keine Kernel- oder Firmwarepartitionen überschreiben.

VNC lauscht nur auf `127.0.0.1:5963`. Die echten Kobo-Touch- und Framebuffer-Geräte werden nicht in Android eingebunden. Im Namespace-Fallback teilen Android-Prozesse zusätzlich Mount- und PID-Namespace mit dem Host; ein Fehler kann dann den Kobo beeinflussen. Android teilt sich immer Kernel und Netzwerkstack mit dem Host. KitKat ist veraltet; nur mit vertrauenswürdigen Apps und ausgeschaltetem WLAN experimentieren und keine persönlichen Konten einrichten. Vor dem ersten Test ein Backup anlegen. Belegte Hardwaregrenzen stehen in [docs/ARCHITEKTUR.md](docs/ARCHITEKTUR.md).

## Lokale Prüfungen

Auf Linux mit GCC, Make, Python 3 und LuaJIT:

```sh
make -C native clean all
python3 -m unittest discover -s tests -p 'test_*.py' -v
luajit tests/test_lua.lua
shellcheck -S warning runtime/*.sh scripts/*.sh
```

Die Hosttests prüfen Fake-Framebuffer, RFB-Protokoll und Pixelformate, beschädigte Eingaben, Installer, Lua-Parser und Buildskripte. Sie starten Android nicht. Ein echter Kobo stand nicht zum Testen zur Verfügung. Der resultierende Download ist deshalb **experimentell und nicht als gerätefertige Android-Portierung verifiziert**.

## Lizenzen

Der neu geschriebene Integrationscode steht unter MIT; siehe [LICENSE](LICENSE). Android- und SDK/NDK-Komponenten behalten ihre jeweiligen Upstream-Lizenzen und Hinweise. Das Paket enthält den im SDK-Systemimage vorhandenen `NOTICE.html.gz`-Hinweis. Die Downloads stammen direkt von Google und werden über feste SHA-256-Prüfsummen verifiziert. Keine proprietären Kobo-/Android-GPU-Blobs und keine fremden kommerziellen APKs werden ergänzt.
