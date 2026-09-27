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
        self.root = Path(self.tmp.name)
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
