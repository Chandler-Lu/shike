#!/usr/bin/env python3
"""Capture eight current App Store scenes from a booted simulator.

For Duo, open and rotate its inner screen in Device Hub first, then pass
--unfolded --display primary-1 to preserve that screen orientation.
"""
import argparse
import re
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('device', help='Simulator UDID')
parser.add_argument('name', help='Unique capture folder name')
parser.add_argument('--display', default='primary')
parser.add_argument('--landscape', action='store_true')
parser.add_argument('--unfolded', action='store_true', help='Preserve the Duo inner-screen orientation set in Device Hub')
parser.add_argument('--without-building', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
folder = root / 'build/store-refresh' / args.name
folder.mkdir(parents=True, exist_ok=True)
result = folder / 'Capture.xcresult'
if result.exists():
    parser.error(f'Result already exists: {result}; choose a new name')
for options in [('ui', args.device, 'appearance', 'light'),
                ('ui', args.device, 'content_size', 'large'),
                ('status_bar', args.device, 'override', '--time', '9:41',
                 '--dataNetwork', 'wifi', '--wifiMode', 'active', '--wifiBars', '3',
                 '--batteryState', 'charged', '--batteryLevel', '100')]:
    subprocess.run(['xcrun', 'simctl', *options], check=True)
test = 'testAppStoreWideScreenshots' if args.landscape else 'testAppStoreScreenshots'
if args.unfolded:
    test = 'testAppStoreUnfoldedScreenshots'
command = ['xcodebuild', 'test-without-building' if args.without_building else 'test',
           '-project', 'Shike.xcodeproj', '-scheme', 'Shike', '-configuration', 'Debug',
           '-destination', f'platform=iOS Simulator,id={args.device}',
           '-derivedDataPath', 'build/UniversalDerived', '-parallel-testing-enabled', 'NO',
           '-collect-test-diagnostics', 'never', '-resultBundlePath', str(result),
           f'-only-testing:ShikeUITests/ShikeUITests/{test}']
captures = set()
with (folder / 'capture.log').open('w') as log:
    process = subprocess.Popen(command, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    for line in process.stdout:
        log.write(line)
        log.flush()
        match = re.search(r"Added attachment named '(store-[^']+)'", line)
        if match:
            name = match[1]
            if name in captures:
                process.terminate()
                raise RuntimeError(f'Duplicate capture: {name}')
            subprocess.run(['xcrun', 'simctl', 'io', args.device, 'screenshot',
                            f'--display={args.display}', str(folder / f'{name}.png')], check=True)
            captures.add(name)
            print(f'Captured {name}', flush=True)
        elif 'error:' in line or 'failed' in line or 'passed' in line:
            print(line.rstrip(), flush=True)
    status = process.wait()
if status == 0 and len(captures) != 8:
    raise RuntimeError(f'Expected 8 screenshots, captured {len(captures)}')
raise SystemExit(status)
