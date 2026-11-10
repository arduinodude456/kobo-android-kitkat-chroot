#!/usr/bin/env bash
# Cross-build Mesa 18.0.5 (softpipe, GLES1/2, EGL) for the KitKat chroot and
# install it into $PRODUCT/system as the "mesa" EGL implementation.
# Run after 00-prebuilt-sdk.sh (needs its NDK, SDK image and $PRODUCT) and
# before 03-rootfs.sh.  SurfaceFlinger keeps libGLES_android.so; see
# native/kobo_egl.c for the per-process selection.
set -euo pipefail
source "$(dirname "$0")/env.sh"

MESA_URL='http://archive.ubuntu.com/ubuntu/pool/main/m/mesa/mesa_18.0.5.orig.tar.gz'
MESA_SHA256='ea3e00329cea899b1e32db812fd2f426832be37e4baa2e2fd9288a3480f30531'
EXPAT_URL='http://archive.ubuntu.com/ubuntu/pool/main/e/expat/expat_2.2.9.orig.tar.gz'
EXPAT_SHA256='c341ac8c79e021cc3392a6d76e138e62d1dd287592cb455148540331756a2208'
# AOSP android-4.4.4_r2 headers (GitHub mirror), pinned by commit.
CORE_COMMIT=efbf36f2dad8f083de6f48dbb682461d7cfa9781
HW_COMMIT=56910cf52332219c6a23bc12596b261c127d93bf
NDK_ZIP="$BUILD/downloads/android-ndk-r10e.zip"
NDK_DIR="$BUILD/ndk10"
NDK="$NDK_DIR/android-ndk-r10e"
TC="$NDK/toolchains/arm-linux-androideabi-4.8/prebuilt/linux-x86_64"
SYSROOT="$NDK/platforms/android-19/arch-arm"
STL="$NDK/sources/cxx-stl/gnu-libstdc++/4.8"
PRODUCT="$AOSP_DIR/out/target/product/libra_colour"
W="$BUILD/mesa"
DEPS="$W/deps"
OUT="$W/out"
JOBS_MESA="${JOBS:-2}"
# llvmpipe (LLVM-JIT, multithreaded) instead of softpipe: MESA_LLVMPIPE=1 builds LLVM first (scripts/05-llvm.sh).
# softpipe stays in the same swrast_dri.so, so KOBO_GLES_LLVMPIPE=0 at runtime still selects it.
MESA_LLVMPIPE="${MESA_LLVMPIPE:-0}"
LLVM_PREFIX="${LLVM_PREFIX:-$BUILD/llvm/prefix}"

[[ -f "$NDK_ZIP" && -d "$PRODUCT/system/lib" ]] || { echo 'run scripts/00-prebuilt-sdk.sh first' >&2; exit 1; }
if [[ "$MESA_LLVMPIPE" = 1 ]]; then
    [[ -x "$LLVM_PREFIX/bin/llvm-config" && -f "$LLVM_PREFIX/.complete" ]] || bash "$ROOT/scripts/05-llvm.sh"
    export LLVM_CONFIG="$LLVM_PREFIX/bin/llvm-config"
fi
unzip -q -o "$NDK_ZIP" 'android-ndk-r10e/sources/cxx-stl/gnu-libstdc++/4.8/*' \
    'android-ndk-r10e/platforms/android-19/arch-arm/usr/include/*' -d "$NDK_DIR"
for lib in libhardware libcutils libsync liblog; do
    [[ -e "$PRODUCT/system/lib/$lib.so" || -e "$SYSROOT/usr/lib/$lib.so" ]] || { echo "missing $lib.so for linking" >&2; exit 1; }
done

rm -rf "$W"; mkdir -p "$W/src" "$DEPS/include" "$DEPS/lib/pkgconfig" "$OUT"
fetch() { # url sha256 file
    curl --fail --location --retry 3 "$1" --output "$3"
    echo "$2  $3" | sha256sum --check
}
fetch "$MESA_URL" "$MESA_SHA256" "$W/mesa.tar.gz"
fetch "$EXPAT_URL" "$EXPAT_SHA256" "$W/expat.tar.gz"
tar -C "$W/src" -xzf "$W/mesa.tar.gz"
tar -C "$W/src" -xzf "$W/expat.tar.gz"
MESA_SRC="$W/src/mesa-18.0.5"

python3 "$ROOT/mesa/apply_patches.py" "$MESA_SRC"

# The patches above edit configure.ac, which makes it newer than the shipped
# aclocal.m4/configure/Makefile.in files.  make would then try to re-run
# aclocal-1.15/autoconf/automake, which the runner does not have.  The tarball
# already contains correctly generated files, so restamp them in dependency
# order (oldest first) to keep make from regenerating anything.
(
    cd "$MESA_SRC"
    touch aclocal.m4; sleep 1
    touch configure; sleep 1
    find . -name Makefile.in -exec touch {} +
    for h in $(find . -name config.h.in); do touch "$h"; done
)

# --- Android 4.4.4 headers --------------------------------------------------
git_pin() { # repo commit dir
    git init -q "$3"; git -C "$3" fetch -q --depth 1 "https://github.com/aosp-mirror/$1.git" "$2"
    git -C "$3" checkout -q FETCH_HEAD
}
git_pin platform_system_core "$CORE_COMMIT" "$W/core"
git_pin platform_hardware_libhardware "$HW_COMMIT" "$W/hw"
cp -r "$W"/core/include/{cutils,system,sync,log,utils} "$DEPS/include/"
cp -r "$W/hw/include/hardware" "$DEPS/include/"

# NDK r10e bionic does not define SIZE_MAX for C99 translation units (ralloc.c
# etc. use it).  Force-include a guarded fallback into every compile.
cat > "$DEPS/include/kobo_compat.h" <<'CFG'
#ifndef KOBO_COMPAT_H
#define KOBO_COMPAT_H
#include <stdint.h>
#ifndef SIZE_MAX
#define SIZE_MAX ((size_t)-1)
#endif
#endif
CFG

# --- toolchain --------------------------------------------------------------
TRIPLE=arm-linux-androideabi
export PATH="$TC/bin:$PATH"
ARCH_FLAGS="-march=armv7-a -mfpu=vfpv3-d16 -mfloat-abi=softfp"
CPPF="--sysroot=$SYSROOT -I$DEPS/include -I$STL/include -I$STL/libs/armeabi-v7a/include -D__ANDROID_API__=19 -include $DEPS/include/kobo_compat.h"
export CC="$TRIPLE-gcc" CXX="$TRIPLE-g++" AR="$TRIPLE-ar" RANLIB="$TRIPLE-ranlib" STRIP="$TRIPLE-strip"
export CC_FOR_BUILD=gcc CXX_FOR_BUILD=g++ CPPFLAGS_FOR_BUILD= CFLAGS_FOR_BUILD=-O1 CXXFLAGS_FOR_BUILD=-O1 LDFLAGS_FOR_BUILD=
# Mesa-Optimierung: softpipe ist reiner C-Code (kein LLVM-JIT) und war bisher ohne NEON und mit -O2
# gebaut. Der Kobo (Cortex-A53, 32-Bit-Userland) hat NEON/VFPv3-D32: mit -mfpu=neon rechnet der
# Compiler Float-Code (Vertex-/Fragment-Interpreter, Rasterizer) deutlich schneller, -fno-math-errno
# erlaubt inline-vsqrt statt libm-Aufrufen. Der ABI bleibt softfp (kompatibel zu den Systembibliotheken).
# Ohne NEON-CPU faellt kobo_egl.c zur Laufzeit auf libGLES_android.so zurueck (siehe cpu_has_neon).
# Ueberschreibbar: MESA_ARCH / MESA_OPT (z. B. MESA_ARCH="$ARCH_FLAGS" MESA_OPT=-O2 fuer den alten Build).
MESA_ARCH="${MESA_ARCH:--march=armv7-a -mfpu=neon -mfloat-abi=softfp -mtune=cortex-a15}"
MESA_OPT="${MESA_OPT:--O3 -fno-math-errno -fno-trapping-math -fomit-frame-pointer}"
export CFLAGS="$MESA_ARCH $MESA_OPT -fPIC $CPPF" CXXFLAGS="$MESA_ARCH $MESA_OPT -fPIC -fno-rtti -fno-exceptions $CPPF"
export LDFLAGS="--sysroot=$SYSROOT -L$DEPS/lib -L$PRODUCT/system/lib -L$STL/libs/armeabi-v7a -Wl,--no-undefined -Wl,-rpath-link=$PRODUCT/system/lib"
export LIBS="-lgnustl_static -llog -ldl"
export PKG_CONFIG_PATH="$DEPS/lib/pkgconfig" PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig"

# expat: the upstream tarball ships no configure script, so compile the three
# library sources directly into a static library.
EXPAT_SRC="$W/src/libexpat-R_2_2_9/expat/lib"
cat > "$EXPAT_SRC/expat_config.h" <<'CFG'
#define BYTEORDER 1234
#define HAVE_MEMMOVE 1
#define XML_CONTEXT_BYTES 1024
#define XML_DTD 1
#define XML_GE 1
#define XML_NS 1
#define XML_DEV_URANDOM 1
CFG
for f in xmlparse xmltok xmlrole; do
    $CC $CFLAGS -DHAVE_EXPAT_CONFIG_H -I"$EXPAT_SRC" -c "$EXPAT_SRC/$f.c" -o "$W/$f.o"
done
$AR rcs "$DEPS/lib/libexpat.a" "$W"/xmlparse.o "$W"/xmltok.o "$W"/xmlrole.o
$RANLIB "$DEPS/lib/libexpat.a"
cp "$EXPAT_SRC/expat.h" "$EXPAT_SRC/expat_external.h" "$DEPS/include/"
printf 'Name: expat\nDescription: expat\nVersion: 2.2.9\nLibs: -lexpat\nCflags: -I%s/include\n' "$DEPS" > "$DEPS/lib/pkgconfig/expat.pc"
# pkg-config files for the Android system libraries and zlib (from the NDK sysroot)
for m in cutils hardware sync; do
    printf 'prefix=%s\nName: %s\nDescription: android %s\nVersion: 4.4.4\nLibs: -l%s\nCflags: -I%s/include\n' "$DEPS" "$m" "$m" "$m" "$DEPS" > "$DEPS/lib/pkgconfig/$m.pc"
done
printf 'Name: zlib\nDescription: zlib\nVersion: 1.2.8\nLibs: -lz\nCflags:\n' > "$DEPS/lib/pkgconfig/zlib.pc"

# --- Mesa -------------------------------------------------------------------
if [[ "$MESA_LLVMPIPE" = 1 ]]; then
    LLVM_ARGS=(--enable-llvm --disable-llvm-shared-libs --with-llvm-prefix="$LLVM_PREFIX")
else
    LLVM_ARGS=(--disable-llvm --disable-llvm-shared-libs)
fi
mkdir -p "$W/build" && cd "$W/build"
"$MESA_SRC/configure" --host=$TRIPLE --build="$(gcc -dumpmachine)" \
    --prefix=/system --libdir=/system/lib \
    --with-dri-driverdir=/system/lib/egl/dri \
    --with-platforms=android --enable-egl --enable-gles1 --enable-gles2 \
    --enable-shared-glapi --enable-dri --with-gallium-drivers=swrast --with-dri-drivers= \
    "${LLVM_ARGS[@]}" \
    --disable-glx --disable-glx-tls --disable-gbm --disable-dri3 --disable-xa --disable-xvmc \
    --disable-vdpau --disable-va --disable-omx-bellagio --disable-opencl --disable-nine \
    --disable-osmesa --disable-libunwind --disable-valgrind --disable-asm
# Belt and braces: never let make invoke the autotools (turns them into no-ops).
AT_OFF=(ACLOCAL=: AUTOCONF=: AUTOMAKE=: AUTOHEADER=:)
make -j"$JOBS_MESA" "${AT_OFF[@]}"
make DESTDIR="$OUT" "${AT_OFF[@]}" install

# --- install into the product tree -------------------------------------------
L="$OUT/system/lib"
sudo install -d -m 0755 "$PRODUCT/system/lib/egl/dri" "$PRODUCT/system/bin"
inst() { "$STRIP" --strip-unneeded -o "$W/stripped" "$1"; sudo install -m 0644 -o root -g root "$W/stripped" "$2"; }
inst "$(readlink -f "$L/libEGL.so")"        "$PRODUCT/system/lib/egl/libEGL_mesa.so"
inst "$(readlink -f "$L/libGLESv1_CM.so")"  "$PRODUCT/system/lib/egl/libGLESv1_CM_mesa.so"
inst "$(readlink -f "$L/libGLESv2.so")"     "$PRODUCT/system/lib/egl/libGLESv2_mesa.so"
inst "$(readlink -f "$L/libglapi.so")"      "$PRODUCT/system/lib/libglapi.so.0"
# Mesa records the unversioned SONAME in DT_NEEDED. Keep the runtime's .so.0
# name and provide the SONAME path expected by KitKat's dynamic linker too.
sudo ln -sfn libglapi.so.0 "$PRODUCT/system/lib/libglapi.so"
inst "$L/egl/dri/swrast_dri.so"             "$PRODUCT/system/lib/egl/dri/swrast_dri.so"
# Marker for platform_android_kobo.c (automatic render scale): llvmpipe is inside swrast_dri.so.
if [[ "$MESA_LLVMPIPE" = 1 ]]; then
    sudo install -m 0644 -o root -g root /dev/null "$PRODUCT/system/lib/egl/dri/llvmpipe.flag"
else
    sudo rm -f "$PRODUCT/system/lib/egl/dri/llvmpipe.flag"
fi

# Fail the build now if the KitKat linker could not dlopen() these libraries (missing NEEDED lib,
# unresolved symbol, TLS, no DT_HASH).  On the device such a failure makes Chrome crash with
# "GPU process isn't usable"; see scripts/verify-mesa-elf.py.
python3 "$ROOT/scripts/verify-mesa-elf.py" --readelf "$TC/bin/$TRIPLE-readelf" \
    --libdir "$PRODUCT/system/lib" --libdir "$PRODUCT/system/lib/egl" \
    "$PRODUCT/system/lib/libglapi.so.0" \
    "$PRODUCT/system/lib/egl/libEGL_mesa.so" "$PRODUCT/system/lib/egl/libGLESv1_CM_mesa.so" \
    "$PRODUCT/system/lib/egl/libGLESv2_mesa.so" "$PRODUCT/system/lib/egl/dri/swrast_dri.so"

# on-device smoke test
"$CC" $ARCH_FLAGS -O2 --sysroot="$SYSROOT" -pie -fPIE "$ROOT/native/kobo_gles_test.c" -o "$W/kobo-gles-test" -lEGL -lGLESv2
sudo install -m 0755 -o root -g root "$W/kobo-gles-test" "$PRODUCT/system/bin/kobo-gles-test"
ls -l "$PRODUCT"/system/lib/egl "$PRODUCT"/system/lib/egl/dri
file "$PRODUCT/system/lib/egl/libEGL_mesa.so" "$PRODUCT/system/lib/egl/dri/swrast_dri.so"
