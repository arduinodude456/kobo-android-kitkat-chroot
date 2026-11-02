#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"

# Official Kobo-Reader source for the Libra Colour / mt8113 vision7 kernel.
KERNEL_COMMIT='7a762964e7fa71ad8e8df50dd1b6eee721a43217'
KERNEL_BASE="https://raw.githubusercontent.com/kobolabs/Kobo-Reader/${KERNEL_COMMIT}/hw/mt8113-libraC_vision7"
PART_AA="$BUILD/downloads/libraC-kernel.tar.zst.part-aa"
PART_AB="$BUILD/downloads/libraC-kernel.tar.zst.part-ab"
PART_AA_SHA256='e17e8787e61d082f49eb098036cb39f1766815c5674c9df5da350666e07c99c4'
PART_AB_SHA256='c00ea64689b57dfa5175f2162b9dc2a1d8084b99a870c65f8fff5dc49596b01d'
KERNEL_ROOT="$BUILD/libraC-kernel"
KERNEL_SRC="$KERNEL_ROOT/linux/v4.9"
KERNEL_OUT="$BUILD/libraC-kernel-out"
CROSS_COMPILE="${CROSS_COMPILE:-arm-linux-gnueabihf-}"

mkdir -p "$BUILD/downloads" "$BUILD/logs"
fetch_verified() {
    local url="$1" file="$2" checksum="$3"
    if [[ ! -f "$file" ]] || ! echo "$checksum  $file" | sha256sum --check --status; then
        curl --fail --location --retry 3 --retry-delay 2 "$url" --output "$file"
    fi
    echo "$checksum  $file" | sha256sum --check
}
fetch_verified "$KERNEL_BASE/kernel.tar.zst.part-aa" "$PART_AA" "$PART_AA_SHA256"
fetch_verified "$KERNEL_BASE/kernel.tar.zst.part-ab" "$PART_AB" "$PART_AB_SHA256"

rm -rf "$KERNEL_ROOT" "$KERNEL_OUT"
mkdir -p "$KERNEL_ROOT" "$KERNEL_OUT"
cat "$PART_AA" "$PART_AB" > "$BUILD/downloads/libraC-kernel.tar.zst"
python3 - "$BUILD/downloads/libraC-kernel.tar.zst" "$BUILD/downloads/libraC-kernel.tar" <<'PY'
import pathlib
import sys
import zstandard
source, target = map(pathlib.Path, sys.argv[1:])
with source.open('rb') as src, target.open('wb') as dst:
    zstandard.ZstdDecompressor().copy_stream(src, dst)
PY
tar -xf "$BUILD/downloads/libraC-kernel.tar" -C "$KERNEL_ROOT"
[[ -f "$KERNEL_SRC/Makefile" && -L "$KERNEL_SRC/arch/arm/configs/aud8113tp1-kobo_defconfig" ]] || {
    echo 'Unexpected Kobo kernel archive layout' >&2
    exit 1
}

make -C "$KERNEL_SRC" O="$KERNEL_OUT" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" aud8113tp1-kobo_defconfig
# Android 4.4 and earlier use the legacy 32-bit Binder ABI. The stock Libra
# kernel config intentionally targets newer userspace and leaves this off.
"$KERNEL_SRC/scripts/config" --file "$KERNEL_OUT/.config" --enable ANDROID_BINDER_IPC_32BIT
make -C "$KERNEL_SRC" O="$KERNEL_OUT" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" olddefconfig
make -C "$KERNEL_SRC" O="$KERNEL_OUT" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS" zImage

[[ -s "$KERNEL_OUT/arch/arm/boot/zImage" ]] || { echo 'Kernel zImage was not produced' >&2; exit 1; }
mkdir -p "$BUILD/kernel"
cp "$KERNEL_OUT/arch/arm/boot/zImage" "$BUILD/kernel/zImage"
printf '%s\n' "$KERNEL_COMMIT" > "$BUILD/kernel/source-commit.txt"
printf '%s\n' 'CONFIG_ANDROID_BINDER_IPC_32BIT=y' > "$BUILD/kernel/config-change.txt"
sha256sum "$BUILD/kernel/zImage" > "$BUILD/kernel/zImage.sha256"
cat > "$BUILD/kernel/README.txt" <<'EOF'
Experimental Kobo Libra Colour kernel build.

This zImage enables CONFIG_ANDROID_BINDER_IPC_32BIT for the Android 4.4
userspace. It is not automatically flashed or merged into the Android ZIP.
Back up the device before any kernel installation and verify that the image
format and signing/upgrade requirements match the exact Kobo firmware.
EOF
printf 'Libra Colour kernel zImage built with Binder IPC 32-bit compatibility.\n'
