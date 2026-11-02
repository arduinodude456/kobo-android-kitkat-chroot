# Android 4.4 für Kobo Libra Colour – experimenteller Chroot

Dieses Repository ersetzt den bisherigen TIC-80-/GeometryRush-Build durch einen **AOSP-Android-4.4.4-ARM32-Build** mit kleiner Software-Anzeige, lokaler VNC-Brücke und KOReader-/AppDock-Anbindung. GitHub Actions soll daraus ein installierbares Paket mit einem ext4-Rootfs und den Kobo-Startern erzeugen.

**Keine Kobo-Ersatzfirmware:** Das Paket startet Android als Chroot auf dem vorhandenen Kobo-Linux-Kernel. Es flasht keinen Kernel und keinen Bootloader. Ob die konkrete Kobo-Firmware die notwendigen Android-Kernel-Funktionen mitbringt, muss auf dem Gerät geprüft werden. Fehlende Binder-/Ashmem-Treiber lassen sich durch dieses Userspace-Paket nicht ersetzen. Ein erfolgreicher Actions-Build beweist deshalb noch keinen Android-Boot auf dem Libra Colour.

## Quellcode-ZIP ins Repository laden

1. Das **Quellcode-ZIP** entpacken und seinen gesamten Inhalt ins Wurzelverzeichnis des Repositorys übernehmen. Nicht das ZIP selbst als einzelne Datei hochladen und keine zusätzliche Verzeichnisebene anlegen.
2. Den versteckten Ordner `.github` mit übernehmen. Die Workflow-Datei muss im Repository unter `.github/workflows/build.yml` liegen. Alte GeometryRush-/TIC-80-Workflows und alte Spiel-Buildskripte entfernen beziehungsweise durch diesen Stand ersetzen.
3. Änderungen auf den Standardbranch übernehmen. Im Reiter **Actions** den Workflow **Android 4.4.4 ARM32 chroot** auswählen und **Run workflow** auslösen. Pushes auf `main` und Pull Requests führen nur die kleinen Tests aus; ausschließlich **Run workflow** startet den großen AOSP-Build.
4. Nach einem erfolgreichen Lauf das Artefakt **kobo-android-kitkat-arm32** herunterladen. Aus dem heruntergeladenen GitHub-Artefakt anschließend **android-kobo.zip** entpacken. Dieses innere ZIP enthält die eigentlichen `.adds/`-Installationsdateien. Die alternative `.tar.gz`-Datei enthält denselben Payload.

GitHub Actions muss für das Repository eingeschaltet sein. Ein Fork kann eine zusätzliche einmalige Freigabe von Actions verlangen. Der manuelle Workflow erscheint erst, wenn die YAML-Datei im Standardbranch liegt.

## Was Actions baut

Die Android-Quellen stammen vom festen AOSP-Tag `android-4.4.4_r2`. Das Produkt verwendet ARM32/ARMv7, Dalvik und einen Software-Grafikpfad statt eines nicht vorhandenen Kobo-Android-GPU-Treibers. Es gibt keine Google-Play-Dienste. Die Buildumgebung für das historische Android bleibt von der aktuellen Runner-Umgebung getrennt; die Quelldownloads laufen mit modernen Host-Werkzeugen.

Die Pipeline baut den eigentlichen Android-Userspace aus Quellen, nicht nur einen Platzhalter mit Android-Namen. Sie integriert `libkobofb.so`, die statischen Helfer `kobo-vnc` und `kobo-container`, erzeugt das ext4-Rootfs und paketiert Starter, KOReader-Plugin, Prüfsummen und Quellmanifest. Das Rootfs bleibt als Dateisystem-Image erhalten, damit Android-Dateirechte und Symlinks auf dem Kobo-Onboard-Speicher nicht verlorengehen.

**Warum nicht KOXToolchain?** [KOXToolchain](https://github.com/koreader/koxtoolchain) ist ein Cross-Compiler für KOReader-Programme und andere native Linux-Binaries auf Kobo, kein Android-SDK oder Android-OS-Builder. Sie könnte einzelne Linux-Helfer bauen, liefert aber nicht Androids Bionic-C-Bibliothek, Binder-Framework, Systemdienste oder System-Apps. Um tatsächlich Android auszuführen, braucht dieses Projekt daher Android-Quellkomponenten wie AOSP.

Das ist ein **großer AOSP-Build**, kein kurzer APK-Build: Der erste Lauf lädt viele Git-Repositories herunter und kann mehrere Stunden dauern; das Workflow-Limit beträgt 350 Minuten. Um auf dem normalen GitHub-Runner mehr nutzbaren Platz zu bekommen, führt der Workflow vor dem Checkout eine auf einen unveränderlichen Commit gepinnte Drittanbieter-Action aus. Sie entfernt ausgewählte, für diesen Job unnötige SDKs und fasst den freien Platz des temporären Laufwerks mit dem Build-Laufwerk zusammen. Die Pipeline verlangt anschließend mindestens 60 GiB nutzbaren Arbeitsraum. Das ist ein Versuch, auf dem Standardrunner auszukommen, aber keine Garantie: GitHub garantiert für Standardrunner nur begrenzte Basiskapazität, der temporäre Datenträger und freigebbare Vorinstallationen können variieren und die LVM-Action nutzt ein undokumentiertes Runner-Detail. Falls die Vorprüfung oder der spätere Build mit `no space left` abbricht, ist ein größerer oder eigener Runner nötig. Diagnoselogs und Quellenstände erscheinen auch bei Fehlern im Artefakt **android-build-provenance-and-logs**. Die Löschschritte gelten ausschließlich für diesen wegwerfbaren GitHub-Runner. Verfügbarkeit alter Upstream-Pakete und Buildwerkzeuge bleibt eine externe Abhängigkeit.

## RAM-schonender Ansatz

Die Android-Anzeige bleibt bewusst bei 600 × 800 Pixeln und RGB565 mit zwei Bildseiten. Die VNC-Brücke benötigt keine externe VNC-Bibliothek. KOReader zeigt das Bild ohne eine zusätzliche Desktop-Umgebung an. Niedrige Dalvik-Heap-Limits, Low-RAM-Einstellungen, deaktivierte Animationen und eine reduzierte Paketauswahl begrenzen unnötige Last.

Damit ist Android aber nicht auf wenige Megabyte reduziert: Zygote, Systemserver, SurfaceFlinger, notwendige Framework-Dienste und Apps benötigen weiterhin Speicher. Es gibt keinen auf dem Gerät gemessenen RAM-Wert und keine Garantie gegen Speicherknappheit bei parallel laufendem Nickel/KOReader. E-Ink begrenzt die wahrnehmbare Bildrate; schnelle Spiele und flüssiges Video sind kein Ziel.

## Auf dem Kobo starten

Das **von Actions erzeugte Installationspaket** entpacken und `.adds/` auf den Kobo kopieren. KOReader muss bereits installiert sein. Das mitgelieferte Plugin ergänzt das Werkzeugmenü um **Android 4.4 (Chroot)**. Der erste Start prüft und entpackt das Rootfs. Das Image enthält anschließend auch die persistenten Android-App-Daten.

Manuell aus einer Kobo-Root-Shell:

```sh
cd /mnt/onboard/.adds/android
sh install.sh
sh android.sh check
sh android.sh start
# Tatsächlichen Android-Bootstatus prüfen:
sh android.sh exec getprop sys.boot_completed
# Vor USB-Datenträgermodus oder Update unbedingt stoppen:
sh android.sh stop
```

`sys.boot_completed` muss schließlich `1` ergeben. Ein offener VNC-Port oder sichtbares Bild allein ist kein vollständiger Bootnachweis. Für AppDock:

```lua
require("appdock_android").open()
```

Die neue Lua-Datei muss dafür im Lua-Suchpfad liegen. Vollständige Installation, APK-Sideloading, Logs und Fehlerbehebung stehen in [docs/KOBO.md](docs/KOBO.md).

## Voraussetzungen und Sicherheit

Erforderlich sind Root-Rechte, ein **KitKat-kompatibler Binder-Treiber**, Ashmem, `uinput`, PID-/Mount-Namespaces, Loop-Geräte und ext4. Der Starter prüft diese Funktionen, erzeugt private Gerätedateien und startet Android-init nur als PID 1 im eigenen PID-Namespace. Ohne erfüllte Voraussetzungen bricht er ab. Keine unpassenden Kernelmodule laden und keine Kernel- oder Firmwarepartitionen überschreiben.

VNC lauscht nur auf `127.0.0.1:5963`. Die echten Kobo-Touch- und Framebuffer-Geräte werden nicht in Android eingebunden. Die Android-Prozesse teilen sich jedoch weiterhin Kernel und Netzwerkstack mit dem Host. KitKat ist veraltet; nur mit vertrauenswürdigen Apps und ausgeschaltetem WLAN experimentieren, keine persönlichen Konten einrichten. Vor dem ersten Test ein Backup anlegen. Details und belegte Hardwaregrenzen stehen in [docs/ARCHITEKTUR.md](docs/ARCHITEKTUR.md).

## Lokale Prüfungen

Auf einem Linux-Entwicklungsrechner mit GCC, Make, Python 3 und LuaJIT:

```sh
make -C native clean all
python3 -m unittest discover -s tests -p 'test_*.py' -v
luajit tests/test_lua.lua
```

Die Tests prüfen unter anderem den Fake-Framebuffer, RFB-Protokoll und Pixelformate, beschädigte Eingaben, den Installer, den Lua-Parser und die AOSP-Integrationsskripte. Für ShellCheck:

```sh
shellcheck -S warning runtime/*.sh scripts/*.sh
```

Die tatsächlichen Prüfungen dieses ausgelieferten Stands sind in [docs/TESTSTATUS.md](docs/TESTSTATUS.md) getrennt von den noch offenen AOSP-/Hardwaretests dokumentiert. Ein vollständiger AOSP-Build wurde beim Erstellen dieses Quellcode-ZIP nicht auf GitHub ausgeführt. Ein echter Kobo stand nicht zur Verfügung. Deshalb ist dies ein implementiertes, hostgetestetes Portierungsprojekt, **keine als gerätefertig verifizierte Android-Portierung**.

## Lizenzen

Der neu geschriebene Integrationscode steht unter MIT; siehe [LICENSE](LICENSE). Android/AOSP, Linux-Header und Buildwerkzeuge behalten ihre jeweiligen eigenen Lizenzen. Der Build muss die zugehörigen Upstream-Hinweise sowie das aufgelöste Quellmanifest mitliefern. Keine proprietären Kobo-/Android-GPU-Blobs und keine fremden kommerziellen APKs sind Bestandteil des Quellcodepakets.
