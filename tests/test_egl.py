# SPDX-License-Identifier: MIT
"""Host tests for the per-process EGL selection and the Mesa build inputs."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

DRIVER = r'''
#include <stdio.h>
#include <string.h>
#include "kobo_egl.h"
static int fails;
static void expect(const char *got, const char *want, const char *what) {
    if ((got == NULL) != (want == NULL) || (got && strcmp(got, want))) {
        printf("FAIL %s: got %s want %s\n", what, got ? got : "NULL", want ? want : "NULL"); fails++; }
}
int main(void) {
    /* Browser: Mesa unabhaengig von all_apps */
    for (int all = 0; all <= 1; all++) {
        expect(kobo_egl_override("ro.hardware.egl", "com.android.chrome", 1, 1, 0, all), "mesa", "chrome egl tag");
        expect(kobo_egl_override("ro.kernel.qemu", "org.mozilla.firefox", 1, 1, 0, all), "0", "firefox qemu");
        expect(kobo_egl_override("ro.hardware.egl", "com.android.chrome:privileged_process0", 1, 1, 0, all), "mesa", "chrome GPU process");
        expect(kobo_egl_override("ro.hardware.egl", "com.android.chrome:sandboxed_process0", 1, 1, 0, all), "mesa", "chrome child");
        expect(kobo_egl_override("ro.hardware.egl", "com.android.browser", 1, 1, 0, all), "mesa", "stock browser/WebView");
        expect(kobo_egl_override("ro.hardware.egl", "/system/bin/kobo-gles-test", 1, 1, 0, all), "mesa", "gles test binary");
    }
    /* Beliebige Apps (Spiele, GLSurfaceView): nur mit all_apps */
    expect(kobo_egl_override("ro.hardware.egl", "com.example.game", 1, 1, 0, 1), "mesa", "generic app");
    expect(kobo_egl_override("ro.kernel.qemu", "com.example.game", 1, 1, 0, 1), "0", "generic app qemu");
    expect(kobo_egl_override("ro.hardware.egl", "com.example.game", 1, 1, 0, 0), NULL, "generic app, apps off");
    /* Systemprozesse behalten libGLES_android.so */
    const char *sys[] = { "/system/bin/surfaceflinger", "surfaceflinger", "/system/bin/bootanimation",
        "system_server", "zygote", "<pre-initialized>", "/system/bin/app_process", "/system/bin/mediaserver",
        "com.android.systemui", "com.android.launcher", "com.android.launcher3", "com.android.keyguard",
        "com.android.inputmethod.latin", "com.android.phone", "/system/bin/other-daemon", NULL };
    for (int i = 0; sys[i]; i++) {
        expect(kobo_egl_override("ro.hardware.egl", sys[i], 1, 1, 0, 1), NULL, sys[i]);
        expect(kobo_egl_override("ro.kernel.qemu", sys[i], 1, 1, 0, 1), NULL, sys[i]);
    }
    /* Schutzbedingungen */
    expect(kobo_egl_override("ro.hardware.egl", "com.android.chrome", 0, 1, 0, 1), NULL, "not libEGL caller");
    expect(kobo_egl_override("ro.hardware.egl", "com.android.chrome", 1, 0, 0, 1), NULL, "mesa unusable (missing or dlopen failed)");
    expect(kobo_egl_override("ro.hardware.egl", "com.android.chrome", 1, 1, 1, 1), NULL, "disabled");
    expect(kobo_egl_override("ro.product.model", "com.android.chrome", 1, 1, 0, 1), NULL, "other key");
    expect(kobo_egl_override("ro.kernel.qemu.gles", "com.android.chrome", 1, 1, 0, 1), NULL, "qemu.gles untouched");
    expect(kobo_egl_override("ro.hardware.egl", "", 1, 1, 0, 1), NULL, "empty process");
    if (kobo_egl_process_wants_mesa(NULL, 1)) { printf("FAIL NULL process\n"); fails++; }
    /* NEON-Pruefung (Mesa ist mit -mfpu=neon gebaut) */
    {
        const char *f[] = { "/tmp/kobo_cpu_neon", "/tmp/kobo_cpu_noneon", "/tmp/kobo_cpu_x86", "/tmp/kobo_cpu_a64" };
        const char *c[] = {
            "processor : 0\nFeatures : half thumb fastmult vfp edsp neon vfpv3 tls vfpv4 idiva\nCPU part : 0xd03\n",
            "processor : 0\nFeatures : half thumb fastmult vfp edsp vfpv3 tls\nCPU part : 0xc09\n",
            "processor : 0\nflags : fpu sse sse2\n",
            "processor : 0\nFeatures : fp asimd evtstrm\n" };
        int want[] = { 1, 0, 1, 1 }, i;
        for (i = 0; i < 4; i++) {
            FILE *fp = fopen(f[i], "w"); fputs(c[i], fp); fclose(fp);
            if (kobo_cpu_has_neon(f[i]) != want[i]) { printf("FAIL neon %d\n", i); fails++; }
            remove(f[i]);
        }
        if (kobo_cpu_has_neon("/nonexistent/cpuinfo") != 1) { printf("FAIL neon missing file\n"); fails++; }
    }
    return fails;
}
'''

STUB = '#define PROP_VALUE_MAX 92\nint __system_property_get(const char *k, char *v);\n'


class EglPolicy(unittest.TestCase):
    def test_policy(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / 'sys').mkdir()
            (tmp / 'sys/system_properties.h').write_text(STUB)
            (tmp / 'driver.c').write_text(DRIVER)
            subprocess.run(['gcc', '-std=gnu99', '-Wall', '-Wextra', '-Werror', '-I', str(tmp),
                            '-I', str(ROOT / 'native'), str(tmp / 'driver.c'),
                            str(ROOT / 'native/kobo_egl.c'), '-ldl', '-o', str(tmp / 'd'),
                            '-Wl,--unresolved-symbols=ignore-all'], check=True)
            subprocess.run([str(tmp / 'd')], check=True)

    def test_mesa_patch_is_pinned(self):
        script = (ROOT / 'mesa/apply_patches.py').read_text()
        self.assertIn("18.0.5", script)
        self.assertTrue((ROOT / 'mesa/platform_android_kobo.c').is_file())
        build = (ROOT / 'scripts/05-mesa.sh').read_text()
        self.assertIn('--disable-glx-tls', build)  # bionic KitKat has no ELF TLS in shared objects
        self.assertIn('MESA_SHA256=', build)
        self.assertIn('verify-mesa-elf.py', build)  # fail the build if dlopen() on KitKat would fail
        self.assertIn('-mfpu=neon', build)  # softpipe is pure C: NEON/-O3 build for speed
        self.assertIn('-O3', build)


if __name__ == '__main__':
    unittest.main()
