#!/usr/bin/env python3
"""Adapt an unpacked Mesa 18.0.5 tree for the Kobo Android chroot (software EGL).

The edits are small and strict: each one must match exactly once, otherwise the
script fails, so a different Mesa version is never patched silently.
"""
import argparse
from pathlib import Path
import shutil
import sys

HERE = Path(__file__).resolve().parent
EGL = Path('src/egl/drivers/dri2')

# (relative file, old text, new text)
EDITS = [
    # The stock platform needs the DRM-aware gralloc header; the software
    # platform in platform_android_kobo.c does not.
    (EGL / 'egl_dri2.h', '#include <gralloc_drm_handle.h>\n', ''),
    # bionic (API 19) has no pthread_mutex_timedlock(): use the busy-loop fallback.
    (Path('include/c11/threads_posix.h'),
     '#if !defined(__CYGWIN__) && !defined(__APPLE__) && !defined(__NetBSD__)\n',
     '#if !defined(__CYGWIN__) && !defined(__APPLE__) && !defined(__NetBSD__) && !defined(__ANDROID__)\n'),
    # NDK r10e: no SYS_futex alias and an old linux/futex.h without the BITSET ops.
    (Path('src/util/futex.h'),
     '#include <sys/syscall.h>\n#include <sys/time.h>\n',
     '#include <sys/syscall.h>\n#include <sys/time.h>\n'
     '#ifndef SYS_futex\n#define SYS_futex __NR_futex\n#endif\n'
     '#ifndef FUTEX_WAIT_BITSET\n#define FUTEX_WAIT_BITSET 9\n#endif\n'
     '#ifndef FUTEX_BITSET_MATCH_ANY\n#define FUTEX_BITSET_MATCH_ANY 0xffffffff\n#endif\n'),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mesa_dir', type=Path)
    args = parser.parse_args()
    root = args.mesa_dir
    if (root / 'VERSION').read_text().strip() != '18.0.5':
        sys.exit('refusing to patch: expected Mesa 18.0.5 in ' + str(root))
    for rel, old, new in EDITS:
        path = root / rel
        text = path.read_text()
        if old in text:
            if text.count(old) != 1:
                sys.exit('ambiguous edit in ' + str(rel))
            path.write_text(text.replace(old, new))
        elif old and new and new in text:
            continue  # already applied
        elif old:
            # old text absent and no replacement present: idempotent only for deletions
            if new == '':
                continue
            sys.exit('edit does not apply to ' + str(rel))
    shutil.copyfile(HERE / 'platform_android_kobo.c', root / EGL / 'platform_android.c')
    print('Mesa 18.0.5 patched for the Kobo software EGL platform')


if __name__ == '__main__':
    main()
