#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"

# ANDROID_API=19 (KitKat, default, experimental, unpinned: the
# first run prints the archive's SHA-256 so it can be pinned afterwards).
ANDROID_API="${ANDROID_API:-19}"
NDK_URL='https://dl.google.com/android/repository/android-ndk-r10e-linux-x86_64.zip'
NDK_SHA256='ee5f405f3b57c4f5c3b3b8b5d495ae12b660e03d2112e4ed5c728d349f1e520c'
case "$ANDROID_API" in
    21)
        SDK_URL='https://dl.google.com/android/repository/sys-img/android/armeabi-v7a-21_r04.zip'
        SDK_SHA256='4f20bb4abff1fcda7fdde510993d2004b0ca330ae6e7a798ffecc3fbf6d48520'
        ;;
    19)
        SDK_URL="${SDK_URL_OVERRIDE:-https://dl.google.com/android/repository/sys-img/android/armeabi-v7a-19_r05.zip}"
        SDK_SHA256="${SDK_SHA256_OVERRIDE:-}"
        ;;
    *) echo "ANDROID_API must be 19 or 21" >&2; exit 1 ;;
esac
NDK_PLATFORM="android-$ANDROID_API"
DOWNLOADS="$BUILD/downloads"
SDK_ZIP="$DOWNLOADS/sdk$ANDROID_API-arm.zip"
NDK_ZIP="$DOWNLOADS/android-ndk-r10e.zip"
SDK_DIR="$BUILD/sdk$ANDROID_API"
NDK_DIR="$BUILD/ndk10"
PRODUCT="$AOSP_DIR/out/target/product/libra_colour"
MOUNT="$BUILD/sdk$ANDROID_API-mount"
mkdir -p "$DOWNLOADS" "$BUILD/logs"

fetch_verified() {
    local url="$1" file="$2" checksum="$3"
    if [[ -z "$checksum" ]]; then
        [[ -f "$file" ]] || curl --fail --location --retry 3 --retry-delay 2 "$url" --output "$file"
        echo "WARNING: $file is NOT pinned. Computed SHA-256 (pin it in this script after review):"
        sha256sum "$file"
        return 0
    fi
    if [[ ! -f "$file" ]] || ! echo "$checksum  $file" | sha256sum --check --status; then
        curl --fail --location --retry 3 --retry-delay 2 "$url" --output "$file"
    fi
    echo "$checksum  $file" | sha256sum --check
}

fetch_verified "$SDK_URL" "$SDK_ZIP" "$SDK_SHA256"
fetch_verified "$NDK_URL" "$NDK_ZIP" "$NDK_SHA256"
rm -rf "$SDK_DIR" "$NDK_DIR" "$PRODUCT"
mkdir -p "$SDK_DIR" "$NDK_DIR" "$PRODUCT/root" "$PRODUCT/system" "$MOUNT"
unzip -q "$SDK_ZIP" -d "$SDK_DIR"
unzip -q "$NDK_ZIP" \
    'android-ndk-r10e/toolchains/arm-linux-androideabi-4.8/prebuilt/linux-x86_64/*' \
    "android-ndk-r10e/platforms/$NDK_PLATFORM/arch-arm/*" -d "$NDK_DIR"

SDK_IMAGE="$SDK_DIR/armeabi-v7a"
[[ -s "$SDK_IMAGE/system.img" && -s "$SDK_IMAGE/ramdisk.img" ]] || {
    echo 'Pinned SDK archive did not contain the expected API-21 ARM image' >&2; exit 1;
}
file "$SDK_IMAGE/system.img" | tee "$BUILD/logs/system-img-type.txt"
file "$SDK_IMAGE/system.img" | grep -qiE 'ext[234]' || {
    echo "system.img is not ext4 (see build/logs/system-img-type.txt); this script cannot unpack it." >&2; exit 1;
}
# Extract the ramdisk as root so its Android uid/gid and modes are retained.
gzip -dc "$SDK_IMAGE/ramdisk.img" | (cd "$PRODUCT/root" && sudo cpio -idm --quiet --no-absolute-filenames)
# Keep the SDK's generated BOOTCLASSPATH, but use only the isolated Kobo init.
sudo install -o root -g root -m 0644 "$ROOT/android/device/kobo/libra_colour/init.rc" "$PRODUCT/root/init.rc"
sudo rm -f "$PRODUCT/root/init.goldfish.rc" "$PRODUCT/root/init.trace.rc" \
    "$PRODUCT/root/init.usb.rc" "$PRODUCT/root/ueventd.goldfish.rc" \
    "$PRODUCT/root/fstab.goldfish"

# The package is a real ext4 system partition. Copy it read-only, preserving
# Android ownership, symlinks, modes and capabilities; never unpack it as user.
sudo mount -t ext4 -o loop,ro,noload "$SDK_IMAGE/system.img" "$MOUNT"
cleanup_mount() { sudo umount "$MOUNT" 2>/dev/null || true; }
trap cleanup_mount EXIT
sudo cp -a "$MOUNT/." "$PRODUCT/system/"
cleanup_mount
trap - EXIT

# Convert the emulator SDK defaults to conservative software-rendered Kobo
# settings. Replace existing keys rather than appending ambiguous duplicates.
sudo python3 - "$PRODUCT/system/build.prop" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
values = {
    'ro.build.product': 'libra_colour',
    'ro.product.device': 'libra_colour',
    'ro.product.name': 'kobo_libra_colour',
    'ro.product.brand': 'KoboChroot',
    'ro.product.model': 'Libra Colour Android Chroot',
    'ro.product.manufacturer': 'community',
    'ro.hardware': 'kobo_libra_colour',
    'ro.kernel.qemu': '0',
    'ro.opengles.version': '65536',
    'ro.sf.lcd_density': '160',
    'ro.config.low_ram': 'true',
    'debug.sf.hw': '0',
    'debug.egl.hw': '0',
    'debug.hwui.render_dirty_regions': 'false',
    'dalvik.vm.heapsize': '96m',
    'dalvik.vm.heapstartsize': '8m',
    'dalvik.vm.heapgrowthlimit': '48m',
    'dalvik.vm.heaptargetutilization': '0.75',
    'dalvik.vm.heapminfree': '512k',
    'dalvik.vm.heapmaxfree': '2m',
    'dalvik.vm.execution-mode': 'int:jit',
    'ro.kernel.android.checkjni': '0',
    'ro.setupwizard.mode': 'DISABLED',
    'debug.sf.nobootanimation': '1',
}
lines = p.read_text().splitlines()
seen = set()
out = []
for line in lines:
    if '=' in line and not line.lstrip().startswith('#'):
        key = line.split('=', 1)[0]
        if key in values:
            if key not in seen:
                out.append(f'{key}={values[key]}')
                seen.add(key)
            continue
    out.append(line)
for key, value in values.items():
    if key not in seen:
        out.append(f'{key}={value}')
p.write_text('\n'.join(out) + '\n')
PY
printf '0 0 android\n' | sudo tee "$PRODUCT/system/lib/egl/egl.cfg" >/dev/null
# Do not let SurfaceFlinger load emulator-only EGL/GLES shims on Kobo.
sudo find "$PRODUCT/system/lib" -type f -name '*_emulation.so' -delete

CC="$NDK_DIR/android-ndk-r10e/toolchains/arm-linux-androideabi-4.8/prebuilt/linux-x86_64/bin/arm-linux-androideabi-gcc"
SYSROOT="$NDK_DIR/android-ndk-r10e/platforms/$NDK_PLATFORM/arch-arm"
NATIVE="$BUILD/native-arm"
mkdir -p "$NATIVE"
COMMON=(--sysroot="$SYSROOT" -march=armv7-a -mfloat-abi=softfp -mfpu=vfpv3-d16 -Os -g0 -std=gnu99 -Wall -Wextra -Wformat=2)
"$CC" "${COMMON[@]}" -fPIC -shared -pthread \
    "$ROOT/native/kobofb.c" "$ROOT/native/kobo_fb.c" "$ROOT/native/kobo_binder.c" \
    -Wl,-soname,libkobofb.so -o "$NATIVE/libkobofb.so"
"$CC" "${COMMON[@]}" "$ROOT/native/kobo_vnc.c" "$ROOT/native/kobo_fb.c" \
    "$ROOT/native/kobo_input.c" -static -pthread -lm -o "$NATIVE/kobo-vnc"
"$CC" "${COMMON[@]}" "$ROOT/runtime/kobo-container.c" -static -o "$NATIVE/kobo-container"
grep -aF 'proc-mount fallback build 2026-11-02e' "$NATIVE/kobo-container" >/dev/null || {
    echo 'kobo-container binary was not rebuilt from the current source' >&2
    exit 1
}
sudo install -o root -g root -m 0644 "$NATIVE/libkobofb.so" "$PRODUCT/system/lib/libkobofb.so"
sudo install -o root -g root -m 0755 "$NATIVE/kobo-vnc" "$PRODUCT/system/bin/kobo-vnc"
sudo install -o root -g root -m 0755 "$NATIVE/kobo-container" "$PRODUCT/system/bin/kobo-container"

cat > "$BUILD/source-manifest.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<prebuilt id="android-5.0.2-api21-armv7a" source="Google Android SDK system image" url="https://dl.google.com/android/repository/sys-img/android/armeabi-v7a-21_r04.zip" sha256="4f20bb4abff1fcda7fdde510993d2004b0ca330ae6e7a798ffecc3fbf6d48520" />
EOF
printf '%s\n' 'Android SDK API 21 ARM EABI v7a system image, build 3079185 (5.0.2)' > "$BUILD/AOSP-RELEASE.txt"
printf '%s\n' 'prebuilt-system-image-sha256:4f20bb4abff1fcda7fdde510993d2004b0ca330ae6e7a798ffecc3fbf6d48520' > "$BUILD/REPO-REVISION.txt"
cat > "$BUILD/patches.json" <<'EOF'
{"mode":"prebuilt-sdk-adaptation","changes":["replace emulator init with isolated Kobo init","set low-RAM software-rendered Kobo properties","remove emulator EGL/GLES shims","build Bionic framebuffer and Kobo helpers with NDK r10e"]}
EOF
cat > "$BUILD/build-container.json" <<'EOF'
{"mode":"prebuilt-download-and-small-native-build","sdk":"Android 5.0.2 API 21 ARM EABI v7a","ndk":"r10e","aosp-full-source-build":false}
EOF
printf 'Prebuilt API-21 ARM SDK staged; only native helpers were compiled.\n'
df -h "$BUILD" | tee "$BUILD/logs/disk-after-prebuilt.log"
