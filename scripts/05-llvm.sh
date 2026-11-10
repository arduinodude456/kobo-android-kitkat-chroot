#!/usr/bin/env bash
# Cross-build a minimal static LLVM 6.0.1 (ARM target only, libraries only) with NDK r10e and install it
# into $BUILD/llvm/prefix together with a small llvm-config wrapper.  Mesa's llvmpipe (gallivm/MCJIT)
# links against it in scripts/05-mesa.sh when MESA_LLVMPIPE=1.
# Needs: build-essential cmake ninja-build python3 curl bzip2 (host) and the NDK from 00-prebuilt-sdk.sh.
# Result: $LLVM_PREFIX/{include,lib/libLLVM*.a,bin/llvm-config}.  Re-running reuses a finished prefix.
set -euo pipefail
source "$(dirname "$0")/env.sh"

LLVM_URL='http://archive.ubuntu.com/ubuntu/pool/main/l/llvm-toolchain-6.0/llvm-toolchain-6.0_6.0.1.orig.tar.bz2'
LLVM_SHA256='aad4f18a7c13665e930e8a4455ffb39a12ea38bbf93bc7d7642a0a2fe81852d4'
L="$BUILD/llvm"
LLVM_PREFIX="${LLVM_PREFIX:-$L/prefix}"
SRC="$L/src/llvm-toolchain-6.0_6.0.1"
NATIVE="$L/native"
CROSS="$L/cross"
NDK_ZIP="$BUILD/downloads/android-ndk-r10e.zip"
NDK_DIR="$BUILD/ndk10"
NDK="$NDK_DIR/android-ndk-r10e"
TC="$NDK/toolchains/arm-linux-androideabi-4.8/prebuilt/linux-x86_64"
SYSROOT="$NDK/platforms/android-19/arch-arm"
STL="$NDK/sources/cxx-stl/gnu-libstdc++/4.8"

if [[ -x "$LLVM_PREFIX/bin/llvm-config" && -f "$LLVM_PREFIX/.complete" ]]; then
    echo "LLVM already built in $LLVM_PREFIX"; exit 0
fi
[[ -f "$NDK_ZIP" ]] || { echo 'run scripts/00-prebuilt-sdk.sh first' >&2; exit 1; }
for tool in cmake ninja python3 curl bzip2; do
    command -v "$tool" >/dev/null || { echo "missing host tool: $tool" >&2; exit 1; }
done
unzip -q -o "$NDK_ZIP" 'android-ndk-r10e/sources/cxx-stl/gnu-libstdc++/4.8/*' \
    'android-ndk-r10e/platforms/android-19/arch-arm/usr/include/*' -d "$NDK_DIR"

rm -rf "$L/src" "$NATIVE" "$CROSS" "$LLVM_PREFIX"
mkdir -p "$L/src" "$L/downloads" "$NATIVE" "$CROSS" "$LLVM_PREFIX/lib" "$LLVM_PREFIX/bin" "$LLVM_PREFIX/include"
if [[ ! -f "$L/downloads/llvm.tar.bz2" ]]; then
    curl --fail --location --retry 3 "$LLVM_URL" --output "$L/downloads/llvm.tar.bz2"
fi
echo "$LLVM_SHA256  $L/downloads/llvm.tar.bz2" | sha256sum --check
tar -C "$L/src" -xjf "$L/downloads/llvm.tar.bz2"
python3 "$ROOT/llvm/apply_patches.py" "$SRC"

# --- 1. native llvm-tblgen (host compiler; -include cstdint for newer host GCCs) ------------------------
cmake -S "$SRC" -B "$NATIVE" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_TARGETS_TO_BUILD=ARM -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_DOCS=OFF -DLLVM_ENABLE_ZLIB=OFF \
    -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_LIBXML2=OFF \
    -DCMAKE_CXX_FLAGS='-include cstdint -include limits'
ninja -C "$NATIVE" -j"$JOBS" llvm-tblgen
TBLGEN="$NATIVE/bin/llvm-tblgen"

# --- 2. cross toolchain file -------------------------------------------------------------------------
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

# --- 3. cross build of the static libraries Mesa needs ---------------------------------------------------
# Threads are OFF on purpose: gnustl 4.8 in NDK r10e has no usable <thread>/<mutex>.  Mesa serializes its
# own use of LLVM per context; set KOBO_LLVM_THREADS=1 to try the pthread build instead.
THREADS=OFF; [[ "${KOBO_LLVM_THREADS:-0}" = 1 ]] && THREADS=ON
cmake -S "$SRC" -B "$CROSS" -G Ninja -DCMAKE_TOOLCHAIN_FILE="$L/android-toolchain.cmake" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS_RELEASE='-O2 -DNDEBUG' -DCMAKE_CXX_FLAGS_RELEASE='-O2 -DNDEBUG' \
    -DLLVM_TABLEGEN="$TBLGEN" -DLLVM_TARGETS_TO_BUILD=ARM \
    -DLLVM_HOST_TRIPLE=arm-linux-androideabi -DLLVM_DEFAULT_TARGET_TRIPLE=arm-linux-androideabi \
    -DLLVM_TARGET_ARCH=ARM -DLLVM_ENABLE_THREADS="$THREADS" -DLLVM_ENABLE_PIC=ON \
    -DLLVM_ENABLE_RTTI=OFF -DLLVM_ENABLE_EH=OFF -DLLVM_ENABLE_ASSERTIONS=OFF \
    -DLLVM_ENABLE_BACKTRACES=OFF -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_FFI=OFF -DLLVM_ENABLE_PLUGINS=OFF \
    -DLLVM_INCLUDE_TOOLS=OFF -DLLVM_INCLUDE_UTILS=OFF -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_DOCS=OFF -DLLVM_BUILD_TOOLS=OFF
ninja -C "$CROSS" -j"$JOBS" \
    LLVMMCJIT LLVMInterpreter LLVMExecutionEngine LLVMRuntimeDyld LLVMBitWriter \
    LLVMMCDisassembler LLVMARMCodeGen LLVMARMAsmPrinter LLVMARMAsmParser LLVMARMDisassembler \
    LLVMARMDesc LLVMARMInfo LLVMipo LLVMScalarOpts LLVMVectorize LLVMInstCombine LLVMAnalysis \
    LLVMTransformUtils LLVMAggressiveInstCombine LLVMIRReader LLVMLinker LLVMObject LLVMProfileData \
    LLVMInstrumentation LLVMCodeGen LLVMSelectionDAG LLVMAsmPrinter LLVMTarget LLVMMCParser LLVMMC \
    LLVMCore LLVMBinaryFormat LLVMSupport LLVMDemangle LLVMAsmParser

# --- 4. install: libraries, headers, llvm-config wrapper ---------------------------------------------------
cp "$CROSS"/lib/libLLVM*.a "$LLVM_PREFIX/lib/"
cp -r "$SRC/include/llvm" "$SRC/include/llvm-c" "$LLVM_PREFIX/include/"
cp -r "$CROSS/include/llvm/." "$LLVM_PREFIX/include/llvm/"
cat > "$LLVM_PREFIX/bin/llvm-config" <<WRAP
#!/bin/sh
# Stand-in for the (non-runnable, cross-built) llvm-config: answers only what Mesa 18.0.5's configure asks.
P="$LLVM_PREFIX"
all_libs() { printf '%s' "-Wl,--start-group"; for f in "\$P"/lib/libLLVM*.a; do printf ' %s' "\$f"; done; echo " -Wl,--end-group"; }
for a in "\$@"; do
    case "\$a" in
        --version) echo 6.0.1 ;;
        --components) echo "arm armasmparser armcodegen armdesc armdisassembler armasmprinter arminfo bitreader bitwriter engine interpreter ipo mcdisassembler mcjit native nativecodegen scalaropts vectorize" ;;
        --targets-built) echo ARM ;;
        --cppflags) echo "-I\$P/include -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS" ;;
        --cxxflags) echo "-I\$P/include -std=c++11 -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS" ;;
        --includedir) echo "\$P/include" ;;
        --libdir) echo "\$P/lib" ;;
        --ldflags) echo "-L\$P/lib" ;;
        --libs) all_libs ;;
        --system-libs) echo "-ldl -lm" ;;
        --shared-mode) echo static ;;
        --link-static|--link-shared) ;;
        -*) echo "llvm-config wrapper: unsupported option \$a" >&2; exit 1 ;;
    esac
done
WRAP
chmod 0755 "$LLVM_PREFIX/bin/llvm-config"
touch "$LLVM_PREFIX/.complete"
ls -l "$LLVM_PREFIX/lib" | head -60
du -sh "$LLVM_PREFIX"
