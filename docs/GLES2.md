# OpenGL ES 2 (Mesa softpipe) für Chrome, Firefox & Co.

Das SDK-Image bringt nur `libGLES_android.so` mit (Software-GLES **1.x**). Chrome und Firefox
brauchen GLES2. Das Projekt baut deshalb Mesa 18.0.5 mit dem CPU-Rasterizer *softpipe* und
einer eigenen Android-EGL-Plattform (`mesa/platform_android_kobo.c`).

## Aufbau

| Teil | Zweck |
| --- | --- |
| `scripts/05-mesa.sh` | Cross-Build (NDK r10e, gcc 4.8) von Mesa + expat; installiert `libEGL_mesa.so`, `libGLESv1_CM_mesa.so`, `libGLESv2_mesa.so`, `libglapi.so.0`, `egl/dri/swrast_dri.so`, `kobo-gles-test` |
| `mesa/platform_android_kobo.c` | Ersetzt Mesas `platform_android.c` (das DRM-Gralloc braucht). Rendert per swrast und kopiert Frames über `dequeueBuffer` → gralloc `lock` → Pixelkonvertierung → `queueBuffer` |
| `native/kobo_egl.c` | In `libkobofb.so`: wählt je Prozess die EGL-Implementierung |
| `ro.opengles.version=131072` | meldet ES 2.0, damit Chrome/Firefox-APKs installierbar sind |

**Warum je Prozess?** SurfaceFlinger erzeugt aus gralloc-Puffern EGLImages (`EGL_ANDROID_image_native_buffer`).
Das kann Mesas swrast nicht. SurfaceFlinger (und bootanimation) bleiben darum bei `libGLES_android.so`;
alle anderen Prozesse laden Mesa. Der Shim überschreibt dafür nur die Property-Lesezugriffe
`ro.hardware.egl` und `ro.kernel.qemu`, und nur wenn sie aus `libEGL.so` kommen. `/data/local/kobo-gles-off`
(leere Datei) schaltet Mesa ab.

## Prüfen

Auf dem Gerät: `sh android.sh exec /system/bin/kobo-gles-test` – erwartet `GL_RENDERER=softpipe`
und `OK`. Auf dem Host: `tests/host/run-egl-fake.sh` (siehe Skriptkopf) lässt die echte Mesa-EGL
gegen ein Fake-ANativeWindow laufen; `python3 -m unittest tests.test_egl` testet die Auswahl-Logik.

## Teststatus (ehrlich)

* Host (x86_64, echte Mesa 18.0.5 + Patch, AOSP-4.4.4-Header): GLES2-Rendering, RGBA/RGBX/BGRA/RGB565-Fenster,
  Pbuffer, surfaceless Context, dequeue/queue/lock-Bilanz – **bestanden**.
* **Nicht getestet:** ARM-Cross-Build mit NDK r10e (dort war kein Download möglich), bionic-KitKat-Laufzeit,
  KitKat-`libEGL`-Loader mit dem Property-Shim, Chrome/Firefox selbst. Erwartbar sind Anpassungen
  beim ersten CI-Lauf (fehlende bionic-Funktionen, configure-Cross-Probleme).

## Grenzen

* softpipe ist langsam (reiner C-Code, kein LLVM/NEON-JIT). Seiten rendern, aber nicht flüssig.
* Kein `EGL_ANDROID_image_native_buffer`: SurfaceTexture/Video-Overlays in Browsern funktionieren nicht.
* Hardwarebeschleunigung der Android-UI (hwui) bleibt wegen `ro.config.low_ram` aus.
* Chrome/Firefox-Versionen müssen KitKat (API 19) unterstützen; die APKs bringt der Nutzer selbst mit.
