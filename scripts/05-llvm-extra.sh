#!/usr/bin/env bash
# Adds LLVM libraries that 05-llvm.sh did not build but that Mesa's llvmpipe link needs
# (libLLVMAsmPrinter -> CodeView/MSF, libLLVMARMCodeGen -> GlobalISel).  Kept separate from 05-llvm.sh on
# purpose: the cached LLVM prefix is keyed on that script, and this only needs minutes instead of hours.
# Idempotent: does nothing when the libraries are already in $LLVM_PREFIX/lib (or lib/parts).
set -euo pipefail
source "$(dirname "$0")/env.sh"

EXTRA_TARGETS=(LLVMDebugInfoCodeView LLVMDebugInfoMSF LLVMDebugInfoDWARF LLVMGlobalISel)
L="$BUILD/llvm"
LLVM_PREFIX="${LLVM_PREFIX:-$L/prefix}"
SRC="$L/src/llvm-toolchain-6.0_6.0.1"
NATIVE="$L/native"
CROSS="$L/cross"
NDK_DIR="$BUILD/ndk10"
NDK="$NDK_DIR/android-ndk-r10e"
TC="$NDK/toolchains/arm-linux-androideabi-4.8/prebuilt/linux-x86_64"
SYSROOT="$NDK/platforms/android-19/arch-arm"
STL="$NDK/sources/cxx-stl/gnu-libstdc++/4.8"
LLVM_URL='http://archive.ubuntu.com/ubuntu/pool/main/l/llvm-toolchain-6.0/llvm-toolchain-6.0_6.0.1.orig.tar.bz2'
LLVM_SHA256='aad4f18a7c13665e930e8a4455ffb39a12ea38bbf93bc7d7642a0a2fe81852d4'

have_all() {
    local t
    for t in "${EXTRA_TARGETS[@]}"; do
        [[ -f "$LLVM_PREFIX/lib/lib$t.a" || -f "$LLVM_PREFIX/lib/parts/lib$t.a" ]] || return 1
    done
}
[[ -f "$LLVM_PREFIX/.complete" ]] || { echo 'LLVM prefix missing: run 05-llvm.sh first' >&2; exit 1; }
if have_all; then echo 'extra LLVM libraries already present'; exit 0; fi

NDK_ZIP="$BUILD/downloads/android-ndk-r10e.zip"
[[ -f "$NDK_ZIP" ]] || { echo 'run scripts/00-prebuilt-sdk.sh first' >&2; exit 1; }
# Same as 05-llvm.sh: the C++ STL and API-19 headers are not in the NDK parts 00-prebuilt-sdk.sh unpacks.
# Without them CMake's std::atomic check fails ("Host compiler must support std::atomic!").
unzip -q -o "$NDK_ZIP" 'android-ndk-r10e/sources/cxx-stl/gnu-libstdc++/4.8/*' \
    'android-ndk-r10e/platforms/android-19/arch-arm/usr/include/*' -d "$NDK_DIR"
mkdir -p "$L/downloads" "$L/src" "$NATIVE" "$CROSS"
if [[ ! -d "$SRC" ]]; then
    [[ -f "$L/downloads/llvm.tar.bz2" ]] || curl --fail --location --retry 3 "$LLVM_URL" --output "$L/downloads/llvm.tar.bz2"
    echo "$LLVM_SHA256  $L/downloads/llvm.tar.bz2" | sha256sum --check
    tar -C "$L/src" -xjf "$L/downloads/llvm.tar.bz2"
fi
python3 "$ROOT/llvm/apply_patches.py" "$SRC"

cmake -S "$SRC" -B "$NATIVE" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_TARGETS_TO_BUILD=ARM -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_DOCS=OFF -DLLVM_ENABLE_ZLIB=OFF \
    -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_LIBXML2=OFF \
    -DCMAKE_CXX_FLAGS='-include cstdint -include limits'
ninja -C "$NATIVE" -j"$JOBS" llvm-tblgen

ARCH_FLAGS='-march=armv7-a -mfpu=neon -mfloat-abi=softfp -mtune=cortex-a15'
cat > "$L/android-toolchain.cmake" <<CMK
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR arm)
set(CMAKE_C_COMPILER   $TC/bin/arm-linux-androideabi-gcc)
set(CMAKE_CXX_COMPILER $TC/bin/arm-linux-androideabi-g++)
set(CMAKE_AR           $TC/bin/arm-linux-androideabi-ar CACHE FILEPATH "")
set(CMAKE_RANLIB       $TC/bin/arm-linux-androideabi-ranlib CACHE FILEPATH "")
set(CMAKE_C_FLAGS_INIT   "--sysroot=$SYSROOT $ARCH_FLAGS -fPIC -D__ANDROID_API__=19")
set(CMAKE_CXX_FLAGS_INIT "--sysroot=$SYSROOT $ARCH_FLAGS -fPIC -D__ANDROID_API__=19 -I$STL/include -I$STL/libs/armeabi-v7a/include")
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
set(CMAKE_FIND_ROOT_PATH $SYSROOT)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
CMK
THREADS=OFF; [[ "${KOBO_LLVM_THREADS:-0}" = 1 ]] && THREADS=ON
cmake -S "$SRC" -B "$CROSS" -G Ninja -DCMAKE_TOOLCHAIN_FILE="$L/android-toolchain.cmake" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS_RELEASE='-O2 -DNDEBUG' -DCMAKE_CXX_FLAGS_RELEASE='-O2 -DNDEBUG' \
    -DLLVM_TABLEGEN="$NATIVE/bin/llvm-tblgen" -DLLVM_TARGETS_TO_BUILD=ARM \
    -DLLVM_HOST_TRIPLE=arm-linux-androideabi -DLLVM_DEFAULT_TARGET_TRIPLE=arm-linux-androideabi \
    -DLLVM_TARGET_ARCH=ARM -DLLVM_ENABLE_THREADS="$THREADS" -DLLVM_ENABLE_PIC=ON \
    -DLLVM_ENABLE_RTTI=OFF -DLLVM_ENABLE_EH=OFF -DLLVM_ENABLE_ASSERTIONS=OFF \
    -DLLVM_ENABLE_BACKTRACES=OFF -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_FFI=OFF -DLLVM_ENABLE_PLUGINS=OFF \
    -DLLVM_INCLUDE_TOOLS=OFF -DLLVM_INCLUDE_UTILS=OFF -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_DOCS=OFF -DLLVM_BUILD_TOOLS=OFF
ninja -C "$CROSS" -j"$JOBS" "${EXTRA_TARGETS[@]}"

# A merged archive from an earlier 05-mesa.sh run would hide the new parts: undo it so the merge is redone.
if [[ -f "$LLVM_PREFIX/lib/libLLVMkobomerged.a" ]]; then
    rm -f "$LLVM_PREFIX/lib/libLLVMkobomerged.a"
    mv "$LLVM_PREFIX"/lib/parts/libLLVM*.a "$LLVM_PREFIX/lib/"
fi
for t in "${EXTRA_TARGETS[@]}"; do cp "$CROSS/lib/lib$t.a" "$LLVM_PREFIX/lib/"; done
ls -l "$LLVM_PREFIX/lib" | grep -E 'CodeView|MSF|DWARF|GlobalISel'
