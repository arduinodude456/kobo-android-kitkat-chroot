# SPDX-License-Identifier: MIT
"""Offline fixtures only: these tests do not build AOSP or boot Android."""
import gzip
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import struct
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import patch_aosp
import rootfs
import package as packager


def fixture_elf(dynamic=False, machine=40):
    data = bytearray(84)
    data[:7] = b'\x7fELF\x01\x01\x01'
    struct.pack_into('<HHI', data, 16, 2, machine, 1)
    struct.pack_into('<I', data, 28, 52)
    struct.pack_into('<HHH', data, 40, 52, 32, 1)
    struct.pack_into('<I', data, 52, 3 if dynamic else 1)
    return bytes(data)


class PatcherTests(unittest.TestCase):
    def test_anchors_fail_closed(self):
        with self.assertRaises(ValueError):
            patch_aosp.replace_once('unchanged', 'not present', 'replacement')
        with self.assertRaises(ValueError):
            patch_aosp.replace_once('twice twice', 'twice', 'replacement')

    def test_unknown_release_is_rejected_without_writes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name in patch_aosp.PATCHES:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('wrong release\n')
            with self.assertRaisesRegex(ValueError, 'source hash mismatch'):
                patch_aosp.apply(root, root / 'patches.json')
            self.assertFalse(list(root.rglob('*.kobo-original')))

    def test_idempotent_and_modified_source_refused(self):
        # A mock patch table exercises the exact production apply/backup/hash
        # mechanism without redistributing or downloading AOSP in unit tests.
        original = b'fixture original\n'
        with tempfile.TemporaryDirectory() as tmp, patch.dict(patch_aosp.PATCHES,
                {'file.c': (hashlib.sha256(original).hexdigest(), lambda s: s + 'fixture patched\n')}, clear=True):
            root = Path(tmp)
            (root / 'file.c').write_bytes(original)
            record = root / 'patches.json'
            patch_aosp.apply(root, record)
            first = (root / 'file.c').read_bytes()
            patch_aosp.apply(root, record)
            self.assertEqual(first, (root / 'file.c').read_bytes())
            self.assertEqual(json.loads(record.read_text())['release'], 'android-4.4.4_r2')
            (root / 'file.c').write_text('local user modification\n')
            with self.assertRaisesRegex(ValueError, 'local changes'):
                patch_aosp.apply(root, record)

    def test_powerctl_is_not_host_reboot(self):
        source = 'int do_powerctl(int nargs, char **args)\n{\n    return android_reboot(1, 0, "");\n}\n'
        result = patch_aosp.patch_builtins(source)
        self.assertIn('return -EPERM', result)
        self.assertNotIn('android_reboot(', result)

    def test_hwui_is_globally_disabled(self):
        source = '\n'.join((
            'public static boolean sRendererDisabled = false;',
            'public static boolean sSystemRendererDisabled = false;',
            'public static boolean isAvailable() {\n        return GLES20Canvas.isAvailable();\n    }',
            'static HardwareRenderer create(boolean translucent) {\n            if (GLES20Canvas.isAvailable()) {\n                return new Gl20Renderer(translucent);\n            }\n            return null;\n        }'))
        result = patch_aosp.patch_hwui(source)
        self.assertIn('sRendererDisabled = true', result)
        self.assertIn('sSystemRendererDisabled = true', result)
        self.assertIn('return false;', result)
        self.assertNotIn('new Gl20Renderer', result)
        self.assertNotIn('GLES20Canvas.isAvailable()', result)

    def test_no_floating_source_fallback(self):
        source = (ROOT / 'scripts/01-source.sh').read_text()
        self.assertIn('--depth=1', source)
        self.assertIn('--repo-rev="$REPO_REV"', source)
        self.assertIn('python3 "$REPO" sync', source)
        self.assertNotIn('|| git clone', source)


class WorkflowTests(unittest.TestCase):
    def test_runner_space_is_reclaimed_before_checkout_and_preflight(self):
        workflow = (ROOT / '.github/workflows/build.yml').read_text()
        reclaim = workflow.index('uses: easimon/maximize-build-space@')
        checkout = workflow.index('uses: actions/checkout@v4', workflow.index('  build:'))
        docker_root = workflow.index('name: Move Docker data onto the expanded build volume')
        preflight = workflow.index('run: scripts/preflight.sh')
        self.assertLess(reclaim, checkout)
        self.assertLess(checkout, docker_root)
        self.assertLess(checkout, preflight)
        self.assertIn("if: github.event_name == 'workflow_dispatch'", workflow)
        self.assertRegex(workflow, r'easimon/maximize-build-space@[0-9a-f]{40}')
        self.assertIn('root-reserve-mb: 2048', workflow)
        self.assertIn('swap-size-mb: 1024', workflow)
        self.assertIn('sudo swapoff -a', workflow)
        self.assertIn('sudo rm -f /swapfile /mnt/swapfile', workflow)
        self.assertIn('DockerRootDir', workflow)
        for setting in ('remove-dotnet: \'true\'', 'remove-android: \'true\'',
                        'remove-haskell: \'true\'', 'remove-codeql: \'true\'',
                        'remove-docker-images: \'true\''):
            self.assertIn(setting, workflow)
        self.assertIn('MINIMUM=$((40 * 1024 * 1024 * 1024))', (ROOT / 'scripts/preflight.sh').read_text())


class RootfsTests(unittest.TestCase):
    def test_static_arm_elf_validation(self):
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / 'helper'
            binary.write_bytes(fixture_elf())
            rootfs.arm_elf(binary, static=True)
            binary.write_bytes(fixture_elf(dynamic=True))
            with self.assertRaisesRegex(ValueError, 'must be static'):
                rootfs.arm_elf(binary, static=True)
            binary.write_bytes(fixture_elf(machine=62))
            with self.assertRaisesRegex(ValueError, 'ELF32 ARM'):
                rootfs.arm_elf(binary)

    def test_file_list_preserves_symlinks(self):
        with tempfile.TemporaryDirectory() as tmp:
            stage = Path(tmp)
            (stage / 'system').mkdir()
            (stage / 'system/a').write_text('content')
            (stage / 'link').symlink_to('system')
            self.assertEqual(list(rootfs.file_list(stage)), ['link', 'system/', 'system/a'])

    def test_compressed_image_requires_ext4_and_correct_size(self):
        with tempfile.TemporaryDirectory() as tmp:
            image = Path(tmp) / 'rootfs.gz'
            image.write_bytes(gzip.compress(b'not an ext4 rootfs'))
            with self.assertRaisesRegex(ValueError, 'not an ext4'):
                packager.validate_compressed_image(image, 4096)
            fixture = bytearray(4096)
            fixture[1080:1082] = b'\x53\xef'
            image.write_bytes(gzip.compress(fixture))
            packager.validate_compressed_image(image, 4096)
            with self.assertRaisesRegex(ValueError, 'size mismatch'):
                packager.validate_compressed_image(image, 8192)

    def test_dedicated_init_has_no_host_actions(self):
        text = (ROOT / 'android/device/kobo/libra_colour/init.rc').read_text()
        actions = [line.strip() for line in text.splitlines() if line.strip() and not line.lstrip().startswith('#')]
        self.assertEqual([line for line in actions if line.startswith('import ')], ['import /init.environ.rc'])
        for unsafe in ('mount ', 'write /sys/', 'write /proc/sys/', 'setenforce ', 'start ueventd', 'powerctl '):
            self.assertFalse(any(line.startswith(unsafe) for line in actions), unsafe)
        self.assertTrue(any('--start-system-server' in line for line in actions))


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        self.root, self.build, self.product, self.dist = [self.base / name for name in ('repo', 'build', 'product', 'dist')]
        for path in (self.root, self.build, self.product): path.mkdir()
        for name in ('runtime/android.sh', 'runtime/install.sh', 'runtime/config', 'runtime/kobo-container.c',
                     'lua/appdock_android.lua', 'lua/android.koplugin/main.lua', 'lua/android.koplugin/_meta.lua',
                     'README.md', 'LICENSE', 'android/SOURCES.md', 'native/Android.mk',
                     'android/device/kobo/libra_colour/init.rc', 'scripts/04-package.sh'):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('explicit packaging fixture\n')
        for name in ('source-manifest.xml', 'AOSP-RELEASE.txt', 'REPO-REVISION.txt', 'patches.json', 'build-container.json'):
            (self.build / name).write_text('fixture\n')
        compressed = gzip.compress(b'explicit synthetic package fixture, not an Android image')
        (self.build / 'rootfs.img.gz').write_bytes(compressed)
        (self.build / 'rootfs.img.gz.sha256').write_text(hashlib.sha256(compressed).hexdigest() + '  rootfs.img.gz\n')
        (self.build / 'rootfs.size').write_text(str(768 * 1024 * 1024) + '\n')
        for name in ('kobo-vnc', 'kobo-container'):
            binary = self.product / 'system/bin' / name
            binary.parent.mkdir(parents=True, exist_ok=True)
            binary.write_bytes(fixture_elf())
        notice = self.product / 'system/etc/NOTICE.html.gz'
        notice.parent.mkdir(parents=True, exist_ok=True)
        notice.write_bytes(gzip.compress(b'fixture notice'))

    def tearDown(self):
        self.tmp.cleanup()

    def test_archive_layout_and_checksums(self):
        # Only ext4 content verification is mocked: its independent tests above
        # reject invalid payloads, and a synthetic fixture is not a boot claim.
        with patch.object(packager, 'validate_compressed_image') as validate:
            archive = packager.package(self.root, self.build, self.product, self.dist)
            validate.assert_called_once()
        with tarfile.open(archive) as tar:
            names = tar.getnames()
            for name in ('.adds/android/rootfs.img.gz', '.adds/android/bin/kobo-vnc',
                         '.adds/android/bin/kobo-container', '.adds/android/lua/appdock_android.lua',
                         '.adds/koreader/plugins/android.koplugin/main.lua', 'manifest.json', 'SHA256SUMS'):
                self.assertIn(name, names)
            info = tar.getmember('.adds/android/bin/kobo-vnc')
            self.assertEqual(info.mode & 0o777, 0o755)
            manifest = json.load(tar.extractfile('manifest.json'))
            self.assertFalse(manifest['hardware_tested'])
        with zipfile.ZipFile(self.dist / 'android-kobo.zip') as zipped:
            self.assertIn('.adds/android/rootfs.img.gz', zipped.namelist())
        for line in (self.dist / 'pkg/SHA256SUMS').read_text().splitlines():
            checksum, name = line.split('  ', 1)
            self.assertEqual(checksum, packager.sha256(self.dist / 'pkg' / name))

    def test_missing_helper_fails_before_archive(self):
        (self.product / 'system/bin/kobo-container').unlink()
        with patch.object(packager, 'validate_compressed_image'), self.assertRaisesRegex(ValueError, 'missing or empty'):
            packager.package(self.root, self.build, self.product, self.dist)
        self.assertFalse(self.dist.exists())

    def test_missing_plugin_fails_before_archive(self):
        (self.root / 'lua/android.koplugin/main.lua').unlink()
        with patch.object(packager, 'validate_compressed_image'), self.assertRaisesRegex(ValueError, 'missing or empty'):
            packager.package(self.root, self.build, self.product, self.dist)
        self.assertFalse(self.dist.exists())

    def test_dynamic_arm_helper_rejected(self):
        (self.product / 'system/bin/kobo-vnc').write_bytes(fixture_elf(dynamic=True))
        with patch.object(packager, 'validate_compressed_image'), self.assertRaisesRegex(ValueError, 'must be static'):
            packager.package(self.root, self.build, self.product, self.dist)


if __name__ == '__main__':
    unittest.main()
