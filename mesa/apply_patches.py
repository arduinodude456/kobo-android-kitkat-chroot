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
    # bionic (API 19) has no pthread_barrier_*: use Mesa's own mutex/condvar
    # util_barrier fallback instead of the pthread one.
    (Path('src/util/u_thread.h'),
     '#if defined(HAVE_PTHREAD) && !defined(__APPLE__)\n\ntypedef pthread_barrier_t util_barrier;',
     '#if defined(HAVE_PTHREAD) && !defined(__APPLE__) && !defined(__ANDROID__)\n\ntypedef pthread_barrier_t util_barrier;'),
    # bionic (API 19) has no pthread_condattr_setclock() (added in API 21).  It
    # is only used for EGL_SYNC_REUSABLE_KHR; keep the default cond clock there.
    (EGL / 'egl_dri2.c',
     '      /* change clock attribute to CLOCK_MONOTONIC */\n'
     '      ret = pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);\n',
     '      /* change clock attribute to CLOCK_MONOTONIC */\n'
     '#ifdef __ANDROID__\n      ret = 0; /* no pthread_condattr_setclock in bionic API 19 */\n'
     '#else\n      ret = pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);\n#endif\n'),
    # Mesa 18.0.5 has no --disable-shader-cache: configure always defines
    # ENABLE_SHADER_CACHE, and disk_cache.c then needs <ftw.h>, which bionic
    # lacks.  Drop the define so the upstream no-cache stubs are used.
    # configure.ac first, then configure, so make does not re-run autoconf.
    (Path('configure.ac'), 'DEFINES="$DEFINES -DENABLE_SHADER_CACHE"\n', ''),
    (Path('configure'), 'DEFINES="$DEFINES -DENABLE_SHADER_CACHE"\n', ''),
    # KOBO llvmpipe JIT: log LLVM fatal errors, resolve JIT symbols ourselves, sane ARM core.
    (Path('src/gallium/auxiliary/gallivm/lp_bld_misc.cpp'),
     '#include <llvm/Support/TargetSelect.h>\n',
     '#include <llvm/Support/TargetSelect.h>\n\n#if defined(__ANDROID__)\n/* KOBO: diagnostics and symbol lookup for the llvmpipe JIT on KitKat (see docs/GLES2.md).\n * LLVM reports fatal JIT errors ("Program used external function ... could not be resolved",\n * "Cannot select ...") with exit(1): no signal, no tombstone, the app just disappears.  Log the\n * reason first, and resolve JIT symbols from libc/libm ourselves instead of relying on how the\n * cross-built LLVM was configured (HAVE_DLOPEN). */\n#include <dlfcn.h>\n#include <stdarg.h>\n#include <stdint.h>\n#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n#include <android/log.h>\n#include <llvm-c/ErrorHandling.h>\n\nstatic void kobo_jit_log(const char *fmt, ...)\n{\n   char buf[512];\n   va_list ap;\n   va_start(ap, fmt);\n   vsnprintf(buf, sizeof buf, fmt, ap);\n   va_end(ap);\n   __android_log_print(ANDROID_LOG_ERROR, "kobo-llvm", "%s", buf);\n}\n\nstatic void kobo_llvm_fatal(const char *reason)\n{\n   kobo_jit_log("LLVM ERROR, Prozess endet gleich per exit(1): %s", reason ? reason : "?");\n}\n\nstatic void kobo_install_llvm_handler(void)\n{\n   static volatile int done;\n   if (__sync_bool_compare_and_swap(&done, 0, 1))\n      LLVMInstallFatalErrorHandler(kobo_llvm_fatal);\n}\n\nstatic uint64_t kobo_resolve_symbol(const std::string &Name)\n{\n   static const char *const libs[] = { NULL, "libm.so", "libc.so", "libdl.so", "libstdc++.so" };\n   unsigned i;\n\n   for (i = 0; i < sizeof libs / sizeof libs[0]; i++) {\n      void *h = dlopen(libs[i], RTLD_NOW);\n      void *p = h ? dlsym(h, Name.c_str()) : NULL;\n      if (p)\n         return (uint64_t)(uintptr_t) p;\n   }\n   return 0;\n}\n#endif\n'),
    (Path('src/gallium/auxiliary/gallivm/lp_bld_misc.cpp'),
     '      virtual void *getPointerToNamedFunction(const std::string &Name,',
     '#if HAVE_LLVM >= 0x0306 && defined(__ANDROID__)\n      /* KOBO: __aeabi_* come from LLVM\'s own libgcc table, everything else from libc/libm. */\n      virtual uint64_t getSymbolAddress(const std::string &Name) {\n         uint64_t addr = 0;\n         if (Name.compare(0, 8, "__aeabi_") != 0)\n            addr = kobo_resolve_symbol(Name);\n         if (!addr)\n            addr = BaseMemoryManager::getSymbolAddressInProcess(Name);\n         if (!addr)\n            kobo_jit_log("JIT-Symbol nicht aufloesbar: %s", Name.c_str());\n         return addr;\n      }\n#endif\n      virtual void *getPointerToNamedFunction(const std::string &Name,'),
    (Path('src/gallium/auxiliary/gallivm/lp_bld_misc.cpp'),
     '   std::string Error;\n#if HAVE_LLVM >= 0x0306\n   EngineBuilder builder(std::unique_ptr<Module>(unwrap(M)));',
     '   std::string Error;\n#if defined(__ANDROID__)\n   kobo_install_llvm_handler();\n#endif\n#if HAVE_LLVM >= 0x0306\n   EngineBuilder builder(std::unique_ptr<Module>(unwrap(M)));'),
    (Path('src/gallium/auxiliary/gallivm/lp_bld_misc.cpp'),
     '   builder.setMCPU(MCPU);',
     '#if defined(__ANDROID__) && defined(__arm__)\n   /* KOBO: LLVM 6 knows only some ARM core ids and answers "generic" otherwise, which means ARMv4T\n    * without VFP/NEON (every float op becomes a libgcc call).  The Kobo userland needs NEON anyway\n    * (kobo_egl.c checks it), so take a NEON/VFPv4/hwdiv core instead.  GALLIVM_MCPU overrides. */\n   std::string KoboCPU = MCPU.str();\n   {\n      const char *envcpu = getenv("GALLIVM_MCPU");\n      if (envcpu && *envcpu)\n         KoboCPU = envcpu;\n      else if (KoboCPU == "generic" || KoboCPU.empty())\n         KoboCPU = "cortex-a15";\n      static volatile int logged;\n      if (__sync_bool_compare_and_swap(&logged, 0, 1))\n         kobo_jit_log("JIT-CPU: %s (LLVM-Host: %s)", KoboCPU.c_str(), MCPU.str().c_str());\n      MCPU = StringRef(KoboCPU);\n   }\n#endif\n   builder.setMCPU(MCPU);'),
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
    shutil.copyfile(HERE / 'droid_convert.h', root / EGL / 'droid_convert.h')
    print('Mesa 18.0.5 patched for the Kobo software EGL platform')


if __name__ == '__main__':
    main()
