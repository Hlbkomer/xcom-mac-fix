#!/usr/bin/env python3
"""Package only reviewed public files; optionally export a clean source checkout."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def public_files():
    names = json.loads((ROOT / 'PUBLIC-FILES.json').read_text())
    if len(names) != len(set(names)):
        raise SystemExit('Duplicate public file')
    result = []
    for name in sorted(names):
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts:
            raise SystemExit(f'Unsafe public path: {name}')
        path = ROOT / relative
        if not path.is_file() or any(p.is_symlink() for p in [path, *path.parents] if p != ROOT.parent):
            raise SystemExit(f'Missing file or symlink: {name}')
        data = path.read_bytes()
        if (b'/' + b'Users/') in data or re.search(rb'gh[pousr]_[A-Za-z0-9]{30,}', data):
            raise SystemExit(f'Private path or token-like content in {name}')
        result.append((name, path, data))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--export-dir', type=Path, help='Create a new public-only source directory')
    args = parser.parse_args()
    files = public_files()  # validate everything before writing output
    if args.export_dir:
        args.export_dir.mkdir(parents=True, exist_ok=False)
        for name, source, data in files:
            target = args.export_dir / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        print(f'Exported {len(files)} reviewed public files')
    version = re.search(r'^VERSION="([^"]+)"', (ROOT / 'installer/install.sh').read_text(), re.M)[1]
    prefix = f'xcom-mac-fix-{version}'
    out = ROOT / 'release' / f'{prefix}.zip'
    out.parent.mkdir(exist_ok=True)
    temporary = out.with_suffix('.zip.tmp')
    checksums = []
    with zipfile.ZipFile(temporary, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, path, data in files:
            info = zipfile.ZipInfo(f'{prefix}/{name}', (2026, 9, 27, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = (0o100755 if path.stat().st_mode & 0o111 else 0o100644) << 16
            archive.writestr(info, data)
            checksums.append(f'{hashlib.sha256(data).hexdigest()}  {name}')
        info = zipfile.ZipInfo(f'{prefix}/SHA256SUMS', (2026, 9, 27, 0, 0, 0))
        info.create_system = 3
        info.external_attr = 0o100644 << 16
        archive.writestr(info, '\n'.join(checksums) + '\n')
    temporary.replace(out)
    digest = hashlib.sha256(out.read_bytes()).hexdigest()
    out.with_suffix('.zip.sha256').write_text(f'{digest}  {out.name}\n')
    print(f'{out.name}: {len(files)} files, {out.stat().st_size:,} bytes, SHA-256 {digest}')


if __name__ == '__main__':
    main()
