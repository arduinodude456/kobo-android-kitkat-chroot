# SPDX-License-Identifier: MIT
"""Host test for scripts/verify-mesa-elf.py using small x86 shared objects."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts/verify-mesa-elf.py'


def cc(tmp, name, src, *flags):
    (tmp / (name + '.c')).write_text(src)
    subprocess.run(['gcc', '-shared', '-fPIC', '-o', str(tmp / 'lib' / name), str(tmp / (name + '.c')),
                    '-Wl,--hash-style=both', *flags], check=True)


@unittest.skipUnless(shutil.which('gcc') and shutil.which('readelf'), 'needs gcc/readelf')
class VerifyElf(unittest.TestCase):
    def run_check(self, tmp, *files):
        return subprocess.run(['python3', str(SCRIPT), '--readelf', 'readelf', '--libdir', str(tmp / 'lib'),
                               *[str(tmp / 'lib' / f) for f in files]], capture_output=True, text=True)

    def test_detects_problems(self):
        with tempfile.TemporaryDirectory() as t:
            tmp = Path(t)
            (tmp / 'lib').mkdir()
            cc(tmp, 'libdep.so', 'int dep_fn(void){return 1;}')
            cc(tmp, 'libgood.so', 'extern int dep_fn(void); int good(void){return dep_fn();}', '-L' + str(tmp / 'lib'), '-ldep')
            cc(tmp, 'libmissing.so', 'extern int nowhere_fn(void); int bad(void){return nowhere_fn();}')
            cc(tmp, 'libtls.so', '__thread int x; int get(void){return x;}')
            cc(tmp, 'libgnu.so', 'int g(void){return 2;}', '-Wl,--hash-style=gnu')
            r = self.run_check(tmp, 'libgood.so')
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            r = self.run_check(tmp, 'libmissing.so')
            self.assertEqual(r.returncode, 1)
            self.assertIn('undefined symbol nowhere_fn', r.stdout)
            r = self.run_check(tmp, 'libtls.so')
            self.assertEqual(r.returncode, 1)
            self.assertIn('TLS', r.stdout)
            r = self.run_check(tmp, 'libgnu.so')
            self.assertEqual(r.returncode, 1)
            self.assertIn('DT_HASH', r.stdout)

    def test_missing_needed_library(self):
        with tempfile.TemporaryDirectory() as t:
            tmp = Path(t)
            (tmp / 'lib').mkdir()
            cc(tmp, 'libdep.so', 'int dep_fn(void){return 1;}')
            cc(tmp, 'libuser.so', 'extern int dep_fn(void); int u(void){return dep_fn();}', '-L' + str(tmp / 'lib'), '-ldep')
            (tmp / 'lib' / 'libdep.so').unlink()
            r = self.run_check(tmp, 'libuser.so')
            self.assertEqual(r.returncode, 1)
            self.assertIn("DT_NEEDED 'libdep.so'", r.stdout)


if __name__ == '__main__':
    unittest.main()
