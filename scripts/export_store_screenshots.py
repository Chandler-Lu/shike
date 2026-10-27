#!/usr/bin/env python3
"""Export real XCTest screenshots and optional promotion assets without resizing UI."""
import argparse
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / 'promotion/assets'
SCENES = [f'store-{i:02}-{name}' for i, name in enumerate(
    ['import', 'results', 'review', 'editor', 'settings', 'planning', 'calendar', 'countdowns'], 1)]
DEVICES = {
    'iphone': ('zh-Hans', (1179, 2556)),
    'duo': ('iphone-duo-zh-Hans', (2853, 2007)),
    'ipad': ('ipad-13-zh-Hans', (2752, 2064)),
}


def attachments(result, test_id, folder):
    folder.mkdir(parents=True)
    subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(result.resolve()),
                    '--output-path', str(folder), '--test-id', test_id], check=True, stdout=subprocess.DEVNULL)
    images = {}
    for test in json.loads((folder / 'manifest.json').read_text()):
        for item in test['attachments']:
            if item['isAssociatedWithFailure']:
                continue
            name = item['suggestedHumanReadableName'].split('_')[0]
            if name in images:
                raise ValueError(f'Duplicate capture: {name}; use a result without retries')
            images[name] = folder / item['exportedFileName']
    return images


def jpeg(source, output, size):
    info = subprocess.check_output(['sips', '-g', 'pixelWidth', '-g', 'pixelHeight', str(source)], text=True)
    if f'pixelWidth: {size[0]}\n' not in info or f'pixelHeight: {size[1]}\n' not in info:
        raise ValueError(f'{source.name}: expected native {size[0]} × {size[1]}; do not upscale')
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['sips', '-s', 'format', 'jpeg', '-s', 'formatOptions', '100', str(source), '--out', str(output)],
                   check=True, stdout=subprocess.DEVNULL)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('result', type=Path, nargs='?', help='iPhone result containing testAppStoreScreenshots')
    parser.add_argument('--native-dir', type=Path, help='Active-display PNGs from capture_store_device.py')
    parser.add_argument('--device', choices=DEVICES, default='iphone')
    parser.add_argument('--format', choices=['jpeg', 'png'], default='jpeg')
    parser.add_argument('--output-root', type=Path, default=ROOT / 'docs/app-store/screenshots')
    parser.add_argument('--watch-result', type=Path)
    parser.add_argument('--promotion', action='store_true', help='Also export native widget and backup views from the iPhone result')
    parser.add_argument('--card-result', type=Path, help='Result containing the native portrait share card renderer')
    args = parser.parse_args()
    if (args.result is None) == (args.native_dir is None):
        parser.error('Provide exactly one of result or --native-dir')
    if args.device != 'iphone' and args.native_dir is None:
        parser.error('Duo/iPad require native active-display captures')
    if args.promotion and (args.result is None or args.device != 'iphone'):
        parser.error('--promotion requires an iPhone result bundle')
    with tempfile.TemporaryDirectory(prefix='shike-materials-') as temp:
        folder = Path(temp)
        phone = ({name: args.native_dir / f'{name}.png' for name in SCENES} if args.native_dir
                 else attachments(args.result, 'ShikeUITests/testAppStoreScreenshots()', folder / 'phone'))
        destination, size = DEVICES[args.device]
        # Validate and convert all eight before replacing any delivered screenshot.
        extension = 'png' if args.format == 'png' else 'jpg'
        if args.format == 'png':
            command = ['swift', str(ROOT / 'scripts/render_store_assets.swift'), '--opaque', *map(str, size)]
            for name in SCENES:
                command.extend([str(phone[name]), str(folder / 'staged' / f'{name}.png')])
            subprocess.run(command, cwd=ROOT, check=True)
        else:
            for name in SCENES:
                jpeg(phone[name], folder / 'staged' / f'{name}.jpg', size)
        output = args.output_root / destination
        output.mkdir(parents=True, exist_ok=True)
        for name in SCENES:
            shutil.copy2(folder / 'staged' / f'{name}.{extension}', output / f'{name}.{extension}')
        print(f'Exported 8 native {args.device} screenshots ({size[0]} × {size[1]}).')
        if args.promotion:
            ASSETS.mkdir(parents=True, exist_ok=True)
            widgets = attachments(args.result, 'CompanionBackupTests/testWidgetsRenderEverySizeAndEmptyStates()', folder / 'widgets')
            backup = attachments(args.result, 'ShikeUITests/testLocalBackupPreviewAndMergeRestore()', folder / 'backup')
            for name, asset in [('store-01-import', 'iphone-import.png'), ('store-08-countdowns', 'iphone-countdowns.png')]:
                shutil.copy2(phone[name], ASSETS / asset)
            shutil.copy2(ROOT / 'docs/app-store/screenshots/zh-Hans/store-06-planning.jpg', ASSETS / 'iphone-planning.jpg')
            shutil.copy2(backup['backup-import-preview'], ASSETS / 'backup-preview.png')
            for family, asset in [('systemSmall', 'widget-small'), ('systemMedium', 'widget-medium'), ('systemLarge', 'widget-large')]:
                shutil.copy2(widgets[f'widget-{family}-light'], ASSETS / f'{asset}.png')
            shutil.copy2(widgets['widget-accessoryRectangular-dark'], ASSETS / 'watch-widget.png')
            print('Updated iPhone, backup and widget promotion assets.')
        if args.watch_result:
            watch = attachments(args.watch_result, 'ShikeWatchUITests/testGroupSelectionPersistsAndDetailsOpenOffline()', folder / 'watch')
            for index, name in enumerate(['all', 'group', 'detail'], 1):
                jpeg(watch[f'watch-{name}'], ROOT / f'docs/app-store/screenshots/watch-zh-Hans/watch-{index:02}-{name}.jpg', (368, 448))
                if args.promotion and name in ('group', 'detail'):
                    shutil.copy2(watch[f'watch-{name}'], ASSETS / f'watch-{name}.png')
            print('Exported 3 native Apple Watch screenshots (368 × 448).')
        if args.card_result:
            card = attachments(args.card_result, 'CountdownServiceTests/testCardImageExportsARealPNGWithLongTitleAndSeconds()', folder / 'card')
            ASSETS.mkdir(parents=True, exist_ok=True)
            shutil.copy2(card['portrait-card-promotion'], ASSETS / 'share-card.png')
            print('Updated native portrait share card.')


if __name__ == '__main__':
    main()
