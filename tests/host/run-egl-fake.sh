#!/usr/bin/env bash
# Build and run tests/host/egl_android_fake.c against a host-built Mesa (see mesa/build-host.sh).
# Usage: tests/host/run-egl-fake.sh <mesa-host-build-dir> <host-android-root> <mesa-src-dir> [out-dir]
set -euo pipefail
BUILD=$(cd "$1" && pwd) ROOT=$(cd "$2" && pwd) SRC=$(cd "$3" && pwd)
OUT=${4:-$BUILD/egl-fake-test}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mkdir -p "$OUT"
gcc -g -O0 -Wall -Wno-unused-result -std=gnu99 \
    -I"$ROOT/include" -I"$SRC/include" \
    "$HERE/egl_android_fake.c" -o "$OUT/egl_android_fake" \
    -L"$BUILD/lib" -L"$ROOT/lib" -lEGL -lGLESv2 -lhardware \
    -Wl,-rpath,"$BUILD/lib" -Wl,-rpath,"$ROOT/lib"
export LIBGL_DRIVERS_PATH="$BUILD/lib/gallium"
export EGL_PLATFORM=android
export GALLIUM_DRIVER=softpipe
"$OUT/egl_android_fake"
