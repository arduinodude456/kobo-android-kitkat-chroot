#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Static check that the cross-built Mesa libraries can be dlopen()ed by the KitKat (API 19) linker.

KitKat's Loader aborts the whole process ("couldn't find an OpenGL ES implementation") when
dlopen() of the Mesa EGL driver fails, and Chrome then dies with "GPU process isn't usable".
The usual reasons are visible in the ELF files, so check them at build time instead of on the
device:

  * a DT_NEEDED library that does not exist in the image
  * an undefined (non-weak) symbol that no library of the image defines (RTLD_NOW fails)
  * a TLS segment / TLS relocations (the API-19 linker cannot relocate them in shared objects)
  * no DT_HASH (only DT_GNU_HASH): the API-19 linker cannot look symbols up in such a library

Usage: verify-mesa-elf.py --readelf arm-linux-androideabi-readelf --libdir DIR [--libdir DIR ...] FILE...
Exit status 1 when any check fails; warnings (symbol only provided by a library that is not in the
NEEDED closure) do not fail the build.
"""
import argparse
import os
import re
import subprocess
import sys


def run(readelf, args):
    return subprocess.run([readelf, '-W'] + args, check=True, capture_output=True, text=True).stdout


class Elf:
    def __init__(self, readelf, path):
        self.path = path
        self.needed, self.soname, self.has_hash, self.has_gnu_hash = [], None, False, False
        for line in run(readelf, ['-d', path]).splitlines():
            m = re.search(r'\((\w+)\)\s+(.*)$', line)
            if not m:
                continue
            tag, val = m.groups()
            if tag == 'NEEDED':
                self.needed.append(val.strip().strip('[]').replace('Shared library: ', '').strip('[]'))
            elif tag == 'SONAME':
                self.soname = val.split('[')[-1].rstrip(']')
            elif tag == 'HASH':
                self.has_hash = True
            elif tag == 'GNU_HASH':
                self.has_gnu_hash = True
        self.tls_segment = any(l.split()[:1] == ['TLS'] for l in run(readelf, ['-l', path]).splitlines())
        self.tls_relocs = sorted({l.split()[2] for l in run(readelf, ['-r', path]).splitlines()
                                  if len(l.split()) > 2 and re.search(r'TLS|TPOFF|DTPMOD|DTPOFF', l.split()[2])})
        self.defined, self.undefined = set(), set()
        for line in run(readelf, ['--dyn-syms', path]).splitlines():
            f = line.split()
            # Num: Value Size Type Bind Vis Ndx Name
            if len(f) < 8 or not f[0].endswith(':') or not f[0][:-1].isdigit():
                continue
            bind, ndx, name = f[4], f[6], f[7].split('@')[0]
            if not name:
                continue
            if ndx == 'UND':
                if bind != 'WEAK':
                    self.undefined.add(name)
            else:
                self.defined.add(name)


def find_lib(name, libdirs):
    for d in libdirs:
        p = os.path.join(d, name)
        if os.path.isfile(p):
            return p
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--readelf', default=os.environ.get('READELF', 'readelf'))
    ap.add_argument('--libdir', action='append', required=True,
                    help='directory searched for NEEDED libraries (like /system/lib)')
    ap.add_argument('files', nargs='+')
    args = ap.parse_args()

    cache = {}

    def load(path):
        path = os.path.realpath(path)
        if path not in cache:
            cache[path] = Elf(args.readelf, path)
        return cache[path]

    # every library of the image, for the "defined somewhere" fallback
    everything = None

    def all_defined():
        nonlocal everything
        if everything is None:
            everything = {}
            for d in args.libdir:
                for fn in sorted(os.listdir(d)):
                    p = os.path.join(d, fn)
                    if os.path.isfile(p) and '.so' in fn:
                        try:
                            for s in load(p).defined:
                                everything.setdefault(s, fn)
                        except (subprocess.CalledProcessError, OSError):
                            pass
        return everything

    failures = warnings = 0
    for f in args.files:
        e = load(f)
        name = os.path.basename(f)
        problems = []
        if e.tls_segment or e.tls_relocs:
            problems.append('TLS (%s): the KitKat linker cannot relocate thread-local storage in shared objects'
                            % (', '.join(e.tls_relocs) or 'PT_TLS'))
        if not e.has_hash:
            problems.append('no DT_HASH (only DT_GNU_HASH): link with -Wl,--hash-style=sysv (or both)')
        closure, queue, missing = {}, list(e.needed), []
        while queue:
            n = queue.pop()
            if n in closure:
                continue
            p = find_lib(n, args.libdir)
            if not p:
                missing.append(n)
                closure[n] = None
                continue
            closure[n] = load(p)
            queue.extend(closure[n].needed)
        for n in sorted(missing):
            problems.append("DT_NEEDED '%s' does not exist in %s" % (n, ' or '.join(args.libdir)))
        provided = set(e.defined)
        for lib in closure.values():
            if lib:
                provided |= lib.defined
        unresolved = sorted(e.undefined - provided)
        extra = all_defined() if unresolved else {}
        for s in unresolved:
            if s in extra:
                warnings += 1
                print('WARN  %s: %s only defined by %s (not in its NEEDED closure)' % (name, s, extra[s]))
            else:
                problems.append('undefined symbol %s (no library of the image defines it; dlopen RTLD_NOW fails)' % s)
        if problems:
            failures += 1
            for p in problems:
                print('FAIL  %s: %s' % (name, p))
        else:
            print('ok    %s (NEEDED: %s)' % (name, ', '.join(e.needed) or '-'))
    if failures:
        print('verify-mesa-elf: %d file(s) would not load on Android 4.4' % failures, file=sys.stderr)
        return 1
    print('verify-mesa-elf: all files look loadable (%d warning(s))' % warnings)
    return 0


if __name__ == '__main__':
    sys.exit(main())
