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
    expect(kobo_egl_override("ro.hardware.egl", "com.android.chrome", 1, 1, 0), "mesa", "app egl tag");
    expect(kobo_egl_override("ro.kernel.qemu", "org.mozilla.firefox", 1, 1, 0), "0", "app qemu");
    expect(kobo_egl_override("ro.hardware.egl", "/system/bin/surfaceflinger", 1, 1, 0), NULL, "sf egl");
    expect(kobo_egl_override("ro.kernel.qemu", "surfaceflinger", 1, 1, 0), NULL, "sf qemu");
    expect(kobo_egl_override("ro.hardware.egl", "/system/bin/bootanimation", 1, 1, 0), NULL, "bootanim");
    expect(kobo_egl_override("ro.hardware.egl", "com.android.chrome", 0, 1, 0), NULL, "not libEGL caller");
    expect(kobo_egl_override("ro.hardware.egl", "com.android.chrome", 1, 0, 0), NULL, "mesa missing");
    expect(kobo_egl_override("ro.hardware.egl", "com.android.chrome", 1, 1, 1), NULL, "disabled");
    expect(kobo_egl_override("ro.product.model", "com.android.chrome", 1, 1, 0), NULL, "other key");
    expect(kobo_egl_override("ro.hardware.egl", "system_server", 1, 1, 0), NULL, "system_server");
    expect(kobo_egl_override("ro.kernel.qemu", "zygote", 1, 1, 0), NULL, "zygote");
    expect(kobo_egl_override("ro.hardware.egl", "com.android.systemui", 1, 1, 0), NULL, "systemui");
    expect(kobo_egl_override("ro.hardware.egl", "com.android.launcher", 1, 1, 0), NULL, "launcher");
    expect(kobo_egl_override("ro.hardware.egl", "com.android.chrome:sandboxed_process0", 1, 1, 0), "mesa", "chrome child");
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


if __name__ == '__main__':
    unittest.main()
