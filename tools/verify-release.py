#!/usr/bin/env python3
"""Verify the release CRC, exact public file set and every recorded checksum."""
import hashlib
import json
from pathlib import Path
import re
import zipfile

root = Path(__file__).resolve().parents[1]
version = re.search(r'^VERSION="([^"]+)"', (root / 'installer/install.sh').read_text(), re.M)[1]
prefix = f'xcom-mac-fix-{version}'
path = root / 'release' / f'{prefix}.zip'
expected_digest = path.with_suffix('.zip.sha256').read_text().split()[0]
assert hashlib.sha256(path.read_bytes()).hexdigest() == expected_digest
allowed = set(json.loads((root / 'PUBLIC-FILES.json').read_text()))
with zipfile.ZipFile(path) as archive:
    assert archive.testzip() is None
    expected = {f'{prefix}/{name}' for name in allowed | {'SHA256SUMS'}}
    assert len(archive.namelist()) == len(expected)
    assert set(archive.namelist()) == expected
    sums = archive.read(f'{prefix}/SHA256SUMS').decode().splitlines()
    assert len(sums) == len(allowed)
    for line in sums:
        digest, name = line.split('  ', 1)
        assert name in allowed
        assert hashlib.sha256(archive.read(f'{prefix}/{name}')).hexdigest() == digest
    assert not any('/experiments/' in name or '/Saves/' in name or '/logs/' in name for name in expected)
print(f'PASS: CRC, archive checksum and {len(allowed)} public file checksums')
