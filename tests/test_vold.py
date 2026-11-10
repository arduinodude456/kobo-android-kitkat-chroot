# SPDX-License-Identifier: MIT
"""Host-Test des Antwortformats von kobo-vold."""
from pathlib import Path
import shutil, subprocess, tempfile, unittest
ROOT = Path(__file__).resolve().parents[1]
CC = shutil.which("gcc")
C = r'''
#define KOBO_VOLD_TEST
#include "../native/kobo_vold.c"
#define CK(c) do { if (!(c)) { printf("FAIL %d\n", __LINE__); return 1; } } while (0)
int main(void) {
    char o[160];
    CK(kv_reply("1 volume list", o, sizeof o) > 0); CK(!strcmp(o, "200 1 Volumes listed."));
    CK(kv_reply("42 asec list", o, sizeof o) > 0); CK(!strcmp(o, "200 42 Command succeeded"));
    CK(kv_reply("7", o, sizeof o) > 0); CK(!strcmp(o, "200 7 Command succeeded"));
    CK(kv_reply("abc volume list", o, sizeof o) == 0);
    CK(kv_reply("", o, sizeof o) == 0);
    CK(kv_volume_line("1 volume list", "/storage/emulated/legacy", o, sizeof o) > 0);
    CK(!strcmp(o, "110 1 sdcard /storage/emulated/legacy 4"));
    CK(kv_volume_line("1 volume list", "nope", o, sizeof o) == 0);
    CK(kv_mkdirs_path("5 volume mkdirs /storage/sdcard/Android/data/a.b/files/", "/storage/sdcard", o, sizeof o) > 0);
    CK(!strcmp(o, "/storage/sdcard/Android/data/a.b/files"));
    CK(kv_mkdirs_path("5 volume mkdirs /storage/sdcard/../data", "/storage/sdcard", o, sizeof o) == 0);
    CK(kv_mkdirs_path("5 volume mkdirs /data/data/x", "/storage/sdcard", o, sizeof o) == 0);
    CK(kv_mkdirs_path("5 volume mkdirs /storage/sdcard2/x", "/storage/sdcard", o, sizeof o) == 0);
    CK(kv_mkdirs_path("5 volume list", "/storage/sdcard", o, sizeof o) == 0);
    puts("ok"); return 0;
}'''
@unittest.skipUnless(CC, "gcc fehlt")
class VoldReply(unittest.TestCase):
    def test_reply(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "tests") as t:
            src = Path(t) / "t.c"; src.write_text(C); exe = Path(t) / "t"
            r = subprocess.run([CC, "-std=gnu99", "-Wall", "-Wextra", "-Werror", "-I", str(ROOT / "native"), str(src), "-o", str(exe)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(subprocess.run([str(exe)], capture_output=True, text=True).stdout.strip(), "ok")
if __name__ == "__main__":
    unittest.main()
