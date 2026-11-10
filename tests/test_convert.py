"""Host tests for the GLES2 frame path (pixel conversion, auto render scale, llvmpipe fallback wiring)."""
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class ConvertTests(unittest.TestCase):
    def test_fast_converters_match_reference(self):
        with tempfile.TemporaryDirectory() as d:
            exe = Path(d) / 'test_convert'
            subprocess.run(['gcc', '-std=gnu99', '-O2', '-Wall', '-Wextra', '-Werror',
                            str(ROOT / 'tests/host/test_convert.c'), '-o', str(exe)], check=True)
            out = subprocess.run([str(exe)], check=True, capture_output=True, text=True).stdout
            self.assertEqual(out.strip(), 'OK')

    def test_patcher_installs_header(self):
        self.assertIn('droid_convert.h', (ROOT / 'mesa/apply_patches.py').read_text())
        self.assertIn('#include "droid_convert.h"', (ROOT / 'mesa/platform_android_kobo.c').read_text())

    def test_auto_scale_and_marker(self):
        platform = (ROOT / 'mesa/platform_android_kobo.c').read_text()
        self.assertIn('llvmpipe.flag', platform)
        self.assertIn('tunable("KOBO_GLES_SCALE", 0)', platform)
        self.assertIn('llvmpipe.flag', (ROOT / 'scripts/05-mesa.sh').read_text())
        self.assertIn('KOBO_GLES_SCALE=0', (ROOT / 'runtime/config').read_text())
        self.assertIn('KOBO_GLES_SCALE:-0', (ROOT / 'runtime/android.sh').read_text())

    def test_workflow_falls_back_to_softpipe(self):
        wf = (ROOT / '.github/workflows/build.yml').read_text()
        self.assertIn('default: true', wf)
        self.assertIn("steps.mesa_llvm.outcome != 'success'", wf)
        self.assertEqual(wf.count('continue-on-error: true'), 3)


if __name__ == '__main__':
    unittest.main()
