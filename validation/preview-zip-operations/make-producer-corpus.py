"""Generate native producer fixtures in a new owned directory; never reset one."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import zipfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--windows-input', type=Path, required=True)
    args = parser.parse_args()
    root = args.output.absolute()
    if platform.system() != 'Darwin' or root.exists() or not root.parent.is_dir() or root.name != 'producer-corpus':
        raise SystemExit('Native Darwin and a new producer-corpus under an existing run are required')
    windows = args.windows_input.read_bytes()
    if hashlib.sha256(windows).hexdigest() != '0154af56faed4b1c0ffd2a8eb0eb135c0f81a4aa5cabe332896ad9eb7e549389':
        raise SystemExit('Frozen Explorer-updated input changed')
    root.mkdir()
    source = root / 'source'
    source.mkdir()
    (source / 'nested').mkdir()
    (source / 'empty').mkdir()
    (source / 'plain.txt').write_bytes(b'MAXPLORER NATIVE PRODUCER CORPUS\n' * 128)
    (source / 'nested' / 'nested.txt').write_bytes(b'Nested synthetic member\n')
    (source / 'caf\u00e9.txt').write_bytes('Unicode synthetic member\n'.encode('utf-8'))
    os.chmod(source / 'plain.txt', 0o640)
    for path in source.rglob('*'):
        os.utime(path, (1706933106, 1706933106), follow_symlinks=False)
    os.utime(source, (1706933106, 1706933106))
    (root / 'windows.zip').write_bytes(windows)
    commands = [
        (['/usr/bin/ditto', '-c', '-k', '--keepParent', str(source), str(root / 'ditto.zip')], None),
        (['/usr/bin/zip', '-q', '-r', str(root / 'infozip.zip'), '.'], source),
        (['/usr/bin/zip', '-0', '-q', '-r', str(root / 'infozip-stored.zip'), '.'], source),
        (['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(source), str(root / 'ditto-sequestered.zip')], None),
    ]
    for argv, cwd in commands:
        if argv[-1] == str(root / 'ditto-sequestered.zip'):
            # Seed foreign metadata only after the original four archives exist.
            # These synthetic attributes prove unrelated AppleDouble records
            # remain compatible with adding a new downloaded member.
            for name, value in (
                ('com.apple.ResourceFork', b'MAXPLORER synthetic foreign resource fork'),
                ('com.apple.FinderInfo', b'TEXTttxt' + bytes(24)),
            ):
                # Apple's system Python does not expose os.setxattr on this Mac.
                subprocess.run(['/usr/bin/xattr', '-w', '-x', name, value.hex(),
                                str(source / 'plain.txt')], check=True, timeout=10)
        subprocess.run(argv, cwd=cwd, check=True, timeout=60)
    archives = []
    for path in sorted(root.glob('*.zip')):
        with zipfile.ZipFile(path) as archive:
            assert archive.testzip() is None
            members = [dict(name=e.filename, method=e.compress_type, flags=e.flag_bits, bytes=e.file_size,
                crc32=f'{e.CRC:08x}', externalAttributes=e.external_attr, extraHex=e.extra.hex(),
                sha256=hashlib.sha256(archive.read(e)).hexdigest()) for e in archive.infolist()]
        archives.append(dict(name=path.name, bytes=path.stat().st_size,
            sha256=hashlib.sha256(path.read_bytes()).hexdigest(), members=members))
    report = {'os': platform.platform(), 'commands': [argv for argv, _ in commands],
              'windowsProvenance': 'Frozen Python-created fixture subsequently updated through observed Windows Explorer operations',
              'reader': 'Python zipfile; all member CRCs verified', 'archives': archives}
    (root / 'manifest.json').write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
    print(json.dumps({'corpus': str(root), 'archives': len(archives), 'allCRCsVerified': True}))


if __name__ == '__main__':
    main()
