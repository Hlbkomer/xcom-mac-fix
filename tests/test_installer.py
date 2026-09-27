"""Offline regression tests: no Wine, Steam, accounts or game files are used."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PAYLOAD = ROOT / 'installer/vendor/mtld3d/d3d9.dll'
SHA = '03bee1a57ab20c30345501a2bc7aad9f4c8093e01e4e0c7c6b60a695cc48f7a1'


class GraphicsInstall(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='xcom test ')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.install = self.root / 'install with spaces'
        self.m3 = self.install / 'wine/lib/wine/d3d9/mtld3d'
        (self.m3 / 'i386-windows').mkdir(parents=True)
        (self.install / 'dl').mkdir()
        self.dst = self.m3 / 'i386-windows/d3d9.dll'

    def run_fix(self, dry=False, here=None):
        # Load the actual installer helpers without its argument dispatch.
        helpers = (ROOT / 'installer/install.sh').read_text().split('# ---------- args ----------')[0]
        script = helpers + '\n' + r'''
HERE="$TEST_HERE"; DIR="$TEST_DIR"; M3="$TEST_M3"; DRY="$TEST_DRY"
. "$HERE/mtld3d-fix.sh"
install_mtld3d_fix
'''
        return subprocess.run(['bash', '-c', script], env={**os.environ,
            'TEST_HERE': str(here or ROOT / 'installer'), 'TEST_DIR': str(self.install),
            'TEST_M3': str(self.m3), 'TEST_DRY': str(int(dry))}, capture_output=True, text=True)

    def test_fresh_install_and_repeat(self):
        self.assertEqual(self.run_fix().returncode, 0)
        self.assertEqual(hashlib.sha256(self.dst.read_bytes()).hexdigest(), SHA)
        before = self.dst.stat().st_mtime_ns
        self.assertEqual(self.run_fix().returncode, 0)
        self.assertEqual(self.dst.stat().st_mtime_ns, before)
        self.assertEqual(list((self.install / 'dl').iterdir()), [])
        self.assertTrue((self.m3 / 'LICENSE.xcom-fix').is_file())

    def test_stale_stamp_does_not_hide_stock_or_damaged_dll(self):
        old = b'old renderer'
        self.dst.write_bytes(old)
        (self.m3 / '.mtld3d-old-version-stamp').touch()
        result = self.run_fix()
        self.assertEqual(result.returncode, 0, result.stderr)
        backup = self.install / 'dl' / ('mtld3d-before-xcom-' + hashlib.sha256(old).hexdigest() + '.dll')
        self.assertEqual(backup.read_bytes(), old)
        self.assertEqual(self.dst.read_bytes(), PAYLOAD.read_bytes())

    def test_dry_run_changes_no_bytes(self):
        self.dst.write_bytes(b'original')
        before = {p.relative_to(self.root): p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        result = self.run_fix(dry=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        after = {p.relative_to(self.root): p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        self.assertEqual(before, after)

    def test_corrupted_payload_fails_before_replacing_existing_dll(self):
        here = self.root / 'bad installer'
        (here / 'vendor/mtld3d').mkdir(parents=True)
        shutil.copy(ROOT / 'installer/mtld3d-fix.sh', here)
        (here / 'vendor/mtld3d/d3d9.dll').write_bytes(b'corrupt')
        self.dst.write_bytes(b'original')
        self.assertNotEqual(self.run_fix(here=here).returncode, 0)
        self.assertEqual(self.dst.read_bytes(), b'original')

    def test_symlink_target_is_not_replaced(self):
        outside = self.root / 'unrelated.dll'
        outside.write_bytes(b'unrelated')
        self.dst.symlink_to(outside)
        self.assertNotEqual(self.run_fix().returncode, 0)
        self.assertTrue(self.dst.is_symlink())
        self.assertEqual(outside.read_bytes(), b'unrelated')

    def test_old_staging_symlink_cannot_overwrite_other_file(self):
        outside = self.root / 'unrelated'
        outside.write_bytes(b'sentinel')
        self.dst.with_name(self.dst.name + '.xcom-tmp').symlink_to(outside)
        result = self.run_fix()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(outside.read_bytes(), b'sentinel')
        self.assertFalse(self.dst.is_symlink())
        self.assertEqual(self.dst.read_bytes(), PAYLOAD.read_bytes())

    def test_correct_hash_symlink_is_still_rejected(self):
        self.dst.symlink_to(PAYLOAD)
        self.assertNotEqual(self.run_fix().returncode, 0)
        self.assertTrue(self.dst.is_symlink())

    def test_symlink_parent_is_rejected(self):
        directory = self.dst.parent
        moved = directory.with_name('outside')
        directory.rename(moved)
        directory.symlink_to(moved, target_is_directory=True)
        self.assertNotEqual(self.run_fix().returncode, 0)
        self.assertEqual(list(moved.iterdir()), [])

    def test_license_symlink_is_not_followed(self):
        outside = self.root / 'unrelated'
        outside.write_bytes(b'sentinel')
        (self.m3 / 'LICENSE.xcom-fix').symlink_to(outside)
        self.assertNotEqual(self.run_fix().returncode, 0)
        self.assertEqual(outside.read_bytes(), b'sentinel')


class PathSafety(unittest.TestCase):
    def helper(self, code, **variables):
        helpers = (ROOT / 'installer/install.sh').read_text().split('# ---------- args ----------')[0]
        return subprocess.run(['bash', '-c', helpers + '\n' + code],
                              env={**os.environ, **variables}, capture_output=True, text=True)

    def test_protected_paths_and_aliases_are_rejected(self):
        home = Path.home()
        for path in ['/', str(home), str(home / 'Documents'),
                     str(home / 'Documents') + '///',
                     str(home / 'Library') + '/../Documents',
                     str(home / 'Documents') + '/.', str(home / 'Library/Application Support')]:
            with self.subTest(path=path):
                self.assertNotEqual(self.helper('checked_install_dir "$TARGET"', TARGET=path).returncode, 0)

    def test_symlink_alias_to_protected_directory_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            alias = Path(directory).resolve() / 'home-alias'
            alias.symlink_to(Path.home(), target_is_directory=True)
            self.assertNotEqual(self.helper('checked_install_dir "$TARGET"', TARGET=str(alias)).returncode, 0)

    def test_new_install_directory_resolves_without_creation(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory).resolve() / 'new install' / 'nested'
            result = self.helper('checked_install_dir "$TARGET"', TARGET=str(target))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), str(target))
            self.assertFalse(target.exists())

    def test_manifest_cannot_delete_arbitrary_marked_file(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory).resolve() / 'unrelated'
            target.write_text('# xcom-mac-fix: generated file\n')
            result = self.helper('DESK_PLAY="$TARGET.play"; DESK_KILL="$TARGET.stop"; remove_desktop_launcher "$TARGET"', TARGET=str(target))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(target.exists())

    def test_write_file_refuses_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            outside = root / 'outside'; outside.write_text('sentinel')
            target = root / 'target'; target.symlink_to(outside)
            result = self.helper('printf replacement | write_file "$TARGET" 644', TARGET=str(target))
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(outside.read_text(), 'sentinel')

    def test_uninstall_requires_matching_manifest_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / 'install.manifest').write_text('mode=free\ndir=/unrelated\n')
            sentinel = root / 'keep'; sentinel.write_text('sentinel')
            result = subprocess.run(['bash', str(ROOT / 'installer/install.sh'), '--uninstall', '--yes', '--dir', str(root)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('manifest directory does not match', result.stderr)
            self.assertTrue(sentinel.exists())

    def test_normal_uninstall_removes_only_fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory).resolve()
            root = parent / 'installation'; root.mkdir()
            (root / 'install.manifest').write_text(f'mode=free\ndir={root}\n')
            outside = parent / 'keep'; outside.write_text('sentinel')
            result = subprocess.run(['bash', str(ROOT / 'installer/install.sh'), '--uninstall', '--yes', '--dir', str(root)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(root.exists())
            self.assertEqual(outside.read_text(), 'sentinel')


class PackageChecks(unittest.TestCase):
    def test_shell_syntax(self):
        scripts = list((ROOT / 'installer').rglob('*.sh')) + [ROOT / 'installer/freewine/bin/x87filter']
        for p in scripts:
            with self.subTest(script=p.name):
                r = subprocess.run(['bash', '-n', str(p)], capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stderr)

    def test_payload_hash(self):
        self.assertEqual(hashlib.sha256(PAYLOAD.read_bytes()).hexdigest(), SHA)


if __name__ == '__main__':
    unittest.main()
