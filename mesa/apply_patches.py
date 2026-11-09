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
