#!/usr/bin/env python3
"""Validate the complete 24-image store delivery and universal artwork, without editing pixels."""
import argparse
import hashlib
import json
import struct
import subprocess
import zlib
from datetime import datetime, timezone
from pathlib import Path

from export_store_screenshots import DEVICES, SCENES


def png_info(path):
    data = path.read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError(f'{path}: not a PNG')
    offset, chunks, dimensions = 8, [], None
    while offset < len(data):
        length = struct.unpack_from('>I', data, offset)[0]
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + length]
        crc = struct.unpack_from('>I', data, offset + 8 + length)[0]
        if zlib.crc32(kind + payload) & 0xffffffff != crc:
            raise ValueError(f'{path}: corrupt {kind!r} chunk')
        chunks.append(kind)
        if kind == b'IHDR':
            width, height, depth, color, _, _, _ = struct.unpack('>IIBBBBB', payload)
            dimensions = (width, height, depth, color)
        offset += length + 12
        if kind == b'IEND':
            break
    if dimensions is None or b'IDAT' not in chunks or b'IEND' not in chunks or offset != len(data):
        raise ValueError(f'{path}: incomplete PNG')
    return dimensions, chunks, hashlib.sha256(data).hexdigest()


def validate(path, relative, expected):
    (width, height, depth, color), chunks, digest = png_info(path)
    if (width, height) != expected:
        raise ValueError(f'{relative}: expected {expected}, found {(width, height)}')
    if depth != 8 or color != 2 or b'tRNS' in chunks:
        raise ValueError(f'{relative}: expected opaque 8-bit RGB PNG')
    metadata = subprocess.check_output(['sips', '-g', 'profile', '-g', 'hasAlpha', str(path)], text=True)
    if 'profile: sRGB IEC61966-2.1' not in metadata or 'hasAlpha: no' not in metadata:
        raise ValueError(f'{relative}: expected sRGB without alpha: {metadata}')
    return {'path': str(relative), 'width': width, 'height': height, 'format': 'PNG',
            'color_space': 'sRGB IEC61966-2.1', 'bits_per_channel': depth,
            'alpha': False, 'bytes': path.stat().st_size, 'sha256': digest}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--capture', action='append', default=[], metavar='DEVICE=DIRECTORY',
                        help='Also verify original native captures and successful XCTest log')
    args = parser.parse_args()
    root = args.directory.resolve()
    records = [validate(root / 'universal-5244x2950.png', Path('universal-5244x2950.png'), (5244, 2950))]
    expected_paths = set()
    for _, (folder, size) in DEVICES.items():
        for scene in SCENES:
            relative = Path('screenshots') / folder / f'{scene}.png'
            expected_paths.add(root / relative)
            records.append(validate(root / relative, relative, size))
    actual = {path for path in (root / 'screenshots').rglob('*.*')
              if path.is_file() and path.name != '.DS_Store' and not path.name.startswith('._')}
    if actual != expected_paths:
        raise ValueError(f'Expected exactly 24 screenshots; unexpected: {actual - expected_paths}')
    captures = []
    for value in args.capture:
        device, location = value.split('=', 1)
        folder = Path(location)
        expected = DEVICES[device][1]
        log = (folder / 'capture.log').read_text()
        if '** TEST SUCCEEDED **' not in log and '** TEST EXECUTE SUCCEEDED **' not in log:
            raise ValueError(f'{device}: screenshot test did not succeed')
        sources = []
        for scene in SCENES:
            path = folder / f'{scene}.png'
            dimensions, _, digest = png_info(path)
            if dimensions[:2] != expected:
                raise ValueError(f'{path}: native size differs from exported size')
            sources.append({'file': path.name, 'width': dimensions[0], 'height': dimensions[1], 'sha256': digest})
        captures.append({'device': device, 'source': str(folder), 'xctest': 'passed', 'native_sources': sources})
    checks_file = root / 'verification/checks.json'
    report = {'validated_at': datetime.now(timezone.utc).isoformat(), 'status': 'passed',
              'screenshot_count': 24, 'universal_count': 1, 'assets': records,
              'native_capture_validation': captures,
              'art_safe_area_xywh': [1921, 660, 1402, 962],
              'artwork_bounds_xywh': {'title': [1981, 704, 1282, 186],
                                     'mascots': [2202, 892, 840, 560], 'tagline': [1981, 1490, 1282, 100]},
              'app_store_connect_preview': 'not_uploaded; previews are local crop checks',
              'implementation_checks': json.loads(checks_file.read_text()) if checks_file.exists() else []}
    (root / 'validation.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print('PASS: 24 screenshots + 1 universal asset; native dimensions, PNG integrity, RGB, sRGB, no alpha.')


if __name__ == '__main__':
    main()
