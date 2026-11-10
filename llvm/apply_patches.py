#!/usr/bin/env python3
"""Adapt an unpacked LLVM 6.0.1 tree so its libraries build with NDK r10e (gcc 4.8, gnustl) for KitKat.

Used only for the static LLVM that Mesa's llvmpipe JIT links against.  Each edit must match exactly
once (or already be applied), so a different LLVM version is never patched silently.
"""
import argparse
import re
from pathlib import Path
import sys

# (relative file, regex, replacement)
EDITS = [
    # NDK r10e's gnustl 4.8 has no usable std::call_once/<mutex>: take LLVM's own atomic-based llvm::call_once.
    (Path('include/llvm/Support/Threading.h'),
     r'#elif defined\(LLVM_ON_UNIX\)', '#elif 0 && defined(LLVM_ON_UNIX)'),
    # std::to_string is missing in gnustl 4.8 (only used by the ASan pass, which IPO links in).
    (Path('lib/Transforms/Instrumentation/AddressSanitizer.cpp'),
     r'std::to_string\(GetAsanVersion\(M\)\)', 'utostr(GetAsanVersion(M))'),
]

# <thread>/<future> based helpers are not needed by Mesa and do not build with gnustl 4.8.  CMake insists
# that every .cpp in a directory is listed, so the files stay in place as empty translation units.
STUBS = [Path('lib/Support/ThreadPool.cpp'), Path('lib/Support/Parallel.cpp'), Path('lib/CodeGen/ParallelCG.cpp')]
STUB_TEXT = '// Intentionally empty: not needed by Mesa llvmpipe, does not build with gnustl 4.8 (NDK r10e).\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('llvm_dir', type=Path)
    root = parser.parse_args().llvm_dir
    version = (root / 'CMakeLists.txt').read_text()
    if not all(s in version for s in ('set(LLVM_VERSION_MAJOR 6)', 'set(LLVM_VERSION_MINOR 0)', 'set(LLVM_VERSION_PATCH 1)')):
        sys.exit('refusing to patch: expected LLVM 6.0.1 in ' + str(root))
    for rel, pattern, new in EDITS:
        path = root / rel
        text = path.read_text()
        matches = len(re.findall(pattern, text))
        if matches == 1:
            path.write_text(re.sub(pattern, lambda m: new, text))
        elif matches == 0 and (new in text or new in ('\n',)):
            continue  # already applied (or a deletion that is already gone)
        else:
            sys.exit('edit does not apply exactly once to %s: %s (%d matches)' % (rel, pattern, matches))
    for rel in STUBS:
        (root / rel).write_text(STUB_TEXT)
    print('LLVM 6.0.1 patched for NDK r10e / KitKat')


if __name__ == '__main__':
    main()
