# OpenGL ES 2 (Mesa softpipe) für Chrome, Firefox & Co.

Das SDK-Image bringt nur `libGLES_android.so` mit (Software-GLES **1.x**). Chrome und Firefox
brauchen GLES2. Das Projekt baut deshalb Mesa 18.0.5 mit dem CPU-Rasterizer *softpipe* und
einer eigenen Android-EGL-Plattform (`mesa/platform_android_kobo.c`).

## Aufbau

| Teil | Zweck |
| --- | --- |
| `scripts/05-mesa.sh` | Cross-Build (NDK r10e, gcc 4.8) von Mesa + expat; installiert `libEGL_mesa.so`, `libGLESv1_CM_mesa.so`, `libGLESv2_mesa.so`, `libglapi.so.0` sowie den benötigten `libglapi.so`-SONAME-Alias, `egl/dri/swrast_dri.so`, `kobo-gles-test` |
| `mesa/platform_android_kobo.c` | Ersetzt Mesas `platform_android.c` (das DRM-Gralloc braucht). Rendert per swrast und kopiert Frames über `dequeueBuffer` → gralloc `lock` → Pixelkonvertierung → `queueBuffer` |
| `native/kobo_egl.c` | In `libkobofb.so`: wählt je Prozess die EGL-Implementierung |
| `ro.opengles.version=131072` | meldet ES 2.0, damit Chrome/Firefox-APKs installierbar sind |

**Warum je Prozess?** SurfaceFlinger erzeugt aus gralloc-Puffern EGLImages (`EGL_ANDROID_image_native_buffer`).
Das kann Mesas swrast nicht. SurfaceFlinger, bootanimation, zygote, system_server, SystemUI, Launcher und Keyguard
bleiben darum bei `libGLES_android.so`; **alle anderen App-Prozesse** (Chrome inkl. GPU-Prozess, Firefox, Standard-Browser/WebView,
Spiele, `kobo-gles-test`) laden Mesa. Der Shim überschreibt dafür nur die Property-Lesezugriffe
`ro.hardware.egl` und `ro.kernel.qemu`, und nur wenn sie aus `libEGL.so` kommen.

**Absicherung:** KitKats Loader bricht den Prozess ab (`couldn't find an OpenGL ES implementation`, SIGABRT), wenn das
`dlopen()` des gewählten Treibers scheitert; Chrome meldet dann `GPU process isn't usable. Goodbye.` Der Shim lädt die
drei Mesa-Bibliotheken deshalb vorher selbst, schreibt die echte Linker-Meldung nach `android.log` (Tag `kobo-egl`) und
fällt bei einem Fehler auf `libGLES_android.so` zurück, statt den Prozess abstürzen zu lassen.

Schalter: `/data/local/kobo-gles-off` (leere Datei) schaltet Mesa komplett ab; `KOBO_GLES_APPS=0` (Umgebung oder
`/dev/kobo/tuning`) beschränkt Mesa auf die Browser (altes Verhalten).

## Prüfen

Auf dem Gerät: `sh android.sh gles-test` (läuft mit geladenem Shim, schreibt `gles.txt`) – erwartet `GL_RENDERER=softpipe`
und `OK`. (`android.sh exec` startet ohne Shim und zeigt deshalb nur GLES 1.x.) Auf dem Host: `tests/host/run-egl-fake.sh` (siehe Skriptkopf) lässt die echte Mesa-EGL
gegen ein Fake-ANativeWindow laufen; `python3 -m unittest tests.test_egl` testet die Auswahl-Logik.

## Teststatus (ehrlich)

* Host (x86_64, echte Mesa 18.0.5 + Patch, AOSP-4.4.4-Header): GLES2-Rendering, RGBA/RGBX/BGRA/RGB565-Fenster,
  Pbuffer, surfaceless Context, dequeue/queue/lock-Bilanz – **bestanden**.
* **Nicht getestet:** ARM-Cross-Build mit NDK r10e (dort war kein Download möglich), bionic-KitKat-Laufzeit,
  KitKat-`libEGL`-Loader mit dem Property-Shim, Chrome/Firefox selbst. Erwartbar sind Anpassungen
  beim ersten CI-Lauf (fehlende bionic-Funktionen, configure-Cross-Probleme).

## Leistung

softpipe ist ein reiner C-Rasterizer ohne JIT; ein 3D-Spiel wie Minetest läuft damit bei 600 × 800 nur mit
wenigen Sekunden pro Bild. Maßnahmen im Build (`scripts/05-mesa.sh`):

* Mesa wird mit `-O3 -mfpu=neon -mtune=cortex-a15 -fno-math-errno -fno-trapping-math` gebaut (vorher `-O2`, VFPv3-D16 ohne NEON).
  Der ABI bleibt `softfp`, die Bibliotheken bleiben zu den Systembibliotheken kompatibel. Überschreibbar mit `MESA_ARCH` / `MESA_OPT`
  (alter Build: `MESA_ARCH="-march=armv7-a -mfpu=vfpv3-d16 -mfloat-abi=softfp" MESA_OPT=-O2`).
* Ohne NEON in `/proc/cpuinfo` lädt `kobo_egl.c` Mesa nicht, sondern bleibt bei `libGLES_android.so` (Log-Tag `kobo-egl`).

Das bringt erfahrungsgemäß nur einen Faktor von etwa 1,3 bis 2. Deutlich mehr bringt weniger Rendering-Arbeit in der App
(kleinere Sichtweite, keine Schatten/Shader-Effekte, Texturfilter aus, 3D-Auflösung verringern, sofern die App das anbietet).
Ein echter Sprung wäre nur mit llvmpipe (LLVM-JIT) möglich; das ist ein großer Cross-Build (LLVM für ARM32) und noch nicht umgesetzt.

## Grenzen

* softpipe ist langsam (reiner C-Code, kein LLVM/NEON-JIT). Seiten rendern, aber nicht flüssig.
* Kein `EGL_ANDROID_image_native_buffer`: SurfaceTexture/Video-Overlays in Browsern funktionieren nicht.
* Build-Prüfung: `scripts/verify-mesa-elf.py` (aus `05-mesa.sh`) lässt den Build scheitern, wenn die Mesa-Bibliotheken auf KitKat nicht ladbar wären (fehlende NEEDED-Bibliothek, unaufgelöstes Symbol, TLS, kein DT_HASH).
* Hardwarebeschleunigung der Android-UI (hwui) bleibt wegen `ro.config.low_ram` aus.
* Chrome/Firefox-Versionen müssen KitKat (API 19) unterstützen; die APKs bringt der Nutzer selbst mit.
