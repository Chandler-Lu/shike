#!/usr/bin/env python3
"""Capture the active simulator display during the public promotion UI fixture.

Run at the repository root. Results and logs stay in ignored build/.
Duo must be opened and rotated in Device Hub first; use --display primary-1.
"""
import argparse
import re
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('device', help='Simulator UDID')
parser.add_argument('name', help='Unique output folder name, e.g. ipad')
parser.add_argument('--display', default='primary')
parser.add_argument('--without-building', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
folder = root / 'build/promotion-refresh' / args.name
folder.mkdir(parents=True, exist_ok=True)
result = folder / 'Capture.xcresult'
if result.exists():
    parser.error(f'Result already exists: {result}; choose a new output name')
command = ['xcodebuild', 'test-without-building' if args.without_building else 'test',
           '-project', 'Shike.xcodeproj', '-scheme', 'Shike', '-configuration', 'Debug',
           '-destination', f'platform=iOS Simulator,id={args.device}',
           '-derivedDataPath', 'build/UniversalDerived', '-parallel-testing-enabled', 'NO',
           '-collect-test-diagnostics', 'never', '-resultBundlePath', str(result),
           '-only-testing:ShikeUITests/PlatformWorkspaceUITests/testPromotionWorkspace']
with (folder / 'capture.log').open('w') as log:
    process = subprocess.Popen(command, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    for line in process.stdout:
        log.write(line); log.flush()
        match = re.search(r"Added attachment named '(promotion-[^']+)'", line)
        if match:
            output = folder / f'{match[1]}.png'
            subprocess.run(['xcrun', 'simctl', 'io', args.device, 'screenshot',
                            f'--display={args.display}', str(output)], check=True)
            print(output, flush=True)
    raise SystemExit(process.wait())
