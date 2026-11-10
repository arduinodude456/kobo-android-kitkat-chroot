"""Host tests for the llvmpipe/LLVM cross-build helpers (no NDK or LLVM sources needed)."""
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / 'scripts/05-llvm.sh').read_text()
PATCHER = ROOT / 'llvm/apply_patches.py'


def fake_llvm_tree(root, patch=1):
    files = {
        'CMakeLists.txt': 'set(LLVM_VERSION_MAJOR 6)\nset(LLVM_VERSION_MINOR 0)\nset(LLVM_VERSION_PATCH %d)\n' % patch,
        'include/llvm/Support/Threading.h': '#elif defined(LLVM_ON_UNIX) &&   \\\n    (defined(_LIBCPP_VERSION))\n',
        'lib/Transforms/Instrumentation/AddressSanitizer.cpp': 'x = p + std::to_string(GetAsanVersion(M));\n',
        'include/llvm/ADT/StringExtras.h': 'inline bool to_float(const Twine &T, long double &Num) {\n  return detail::to_float(T, Num, strtold);\n}\n',
        'lib/Support/ThreadPool.cpp': '#include <thread>\n',
        'lib/Support/Parallel.cpp': '#include <thread>\n',
        'lib/CodeGen/ParallelCG.cpp': '#include "x"\n',
    }
    for rel, text in files.items():
        path = Path(root) / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)


class LlvmTests(unittest.TestCase):
    def test_pins(self):
        self.assertRegex(SCRIPT, r"LLVM_SHA256='[0-9a-f]{64}'")
        self.assertIn('llvm-toolchain-6.0_6.0.1.orig.tar.bz2', SCRIPT)
        self.assertIn('-DLLVM_TABLEGEN=', SCRIPT)
        self.assertIn('-DLLVM_TARGETS_TO_BUILD=ARM', SCRIPT)

    def test_patcher_edits_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as d:
            fake_llvm_tree(d)
            for _ in range(2):
                subprocess.run(['python3', str(PATCHER), d], check=True, capture_output=True)
            self.assertIn('#elif 0 && defined(LLVM_ON_UNIX)', (Path(d) / 'include/llvm/Support/Threading.h').read_text())
            self.assertIn('utostr(GetAsanVersion(M))', (Path(d) / 'lib/Transforms/Instrumentation/AddressSanitizer.cpp').read_text())
            self.assertNotIn('strtold', (Path(d) / 'include/llvm/ADT/StringExtras.h').read_text())
            self.assertNotIn('<thread>', (Path(d) / 'lib/Support/ThreadPool.cpp').read_text())

    def test_patcher_refuses_other_version(self):
        with tempfile.TemporaryDirectory() as d:
            fake_llvm_tree(d, patch=2)
            result = subprocess.run(['python3', str(PATCHER), d], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('refusing', result.stderr)

    def test_llvm_config_wrapper_answers_mesa_queries(self):
        template = re.search(r'<<WRAP\n(.*?)\nWRAP\n', SCRIPT, re.S).group(1)
        with tempfile.TemporaryDirectory() as d:
            lib = Path(d) / 'lib'
            lib.mkdir()
            (lib / 'libLLVMSupport.a').write_text('')
            (lib / 'libLLVMCore.a').write_text('')
            script = Path(d) / 'llvm-config'
            expanded = subprocess.run(['bash', '-c', 'LLVM_PREFIX="$1"; eval "cat <<WRAP\n$2\nWRAP"', 'x', d, template],
                                      check=True, capture_output=True, text=True).stdout
            script.write_text(expanded)
            script.chmod(0o755)

            def run(*args):
                return subprocess.run([str(script), *args], check=True, capture_output=True, text=True).stdout.strip()

            self.assertEqual(run('--version'), '6.0.1')
            self.assertEqual(run('--targets-built'), 'ARM')
            for comp in ('bitwriter', 'engine', 'mcdisassembler', 'mcjit'):
                self.assertIn(comp, run('--components').split())
            libs = run('--link-static', '--libs', 'engine', 'mcjit')
            self.assertIn('libLLVMSupport.a', libs)
            self.assertTrue(libs.startswith('-Wl,--start-group') and libs.endswith('-Wl,--end-group'))
            self.assertEqual(run('--link-static', '--system-libs'), '-ldl -lm')
            self.assertEqual(run('--libdir'), str(lib))

    def test_mesa_script_wires_llvmpipe_option(self):
        mesa = (ROOT / 'scripts/05-mesa.sh').read_text()
        self.assertIn('MESA_LLVMPIPE', mesa)
        self.assertIn('--enable-llvm', mesa)
        self.assertIn('--with-llvm-prefix', mesa)
        self.assertIn('--disable-llvm', mesa)  # default stays softpipe-only


if __name__ == '__main__':
    unittest.main()
