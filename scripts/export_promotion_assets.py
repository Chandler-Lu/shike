#!/usr/bin/env python3
"""Export only the sources used by the current five promotion panels."""
import argparse
import shutil
import tempfile
from pathlib import Path
from export_store_screenshots import attachments

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / 'promotion/assets'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--phone', type=Path, required=True)
parser.add_argument('--views-result', type=Path, help='Optional newer card/widget render result')
parser.add_argument('--mac', type=Path, required=True)
parser.add_argument('--ipad', type=Path, required=True, help='Native capture folder')
parser.add_argument('--duo', type=Path, required=True, help='Native capture folder')
parser.add_argument('--watch', type=Path)
parser.add_argument('--card-result', type=Path, required=True)
args = parser.parse_args()
ASSETS.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='shike-promotion-') as temp:
    folder = Path(temp)
    def export(result, test, mapping, subfolder):
        images = attachments(result, test, folder / subfolder)
        for source, dest in mapping.items():
            shutil.copy2(images[source], ASSETS / f'{dest}.png')
    export(args.phone, 'PlatformWorkspaceUITests/testPromotionWorkspace()',
           {'promotion-home': 'iphone-home'}, 'phone')
    export(args.views_result or args.phone, 'CompanionBackupTests/testPromotionViewAssets()',
           {'promotion-color-peach': 'color-peach',
            'promotion-widget-systemMedium': 'widget-medium',
            'promotion-widget-accessoryRectangular': 'watch-widget',
            'promotion-lock': 'lock-widget'}, 'views')
    export(args.phone, 'ShikeUITests/testLocalBackupPreviewAndMergeRestore()',
           {'backup-controls': 'backup-controls', 'backup-import-preview': 'backup-preview'}, 'backup')
    export(args.mac, 'PlatformWorkspaceUITests/testPromotionWorkspace()',
           {'promotion-workspace': 'mac-workspace'}, 'mac')
    shutil.copy2(args.ipad / 'promotion-detail.png', ASSETS / 'ipad-countdowns.png')
    shutil.copy2(args.ipad / 'promotion-planning.png', ASSETS / 'ipad-planning.png')
    shutil.copy2(args.duo / 'promotion-workspace.png', ASSETS / 'duo-workspace.png')
    if args.watch:
        export(args.watch, 'ShikeWatchUITests/testGroupSelectionPersistsAndDetailsOpenOffline()',
               {'watch-detail': 'watch-detail'}, 'watch')
    export(args.card_result, 'CountdownServiceTests/testCardImageExportsARealPNGWithLongTitleAndSeconds()',
           {'portrait-card-promotion': 'share-card'}, 'card')
    for source, name in [('CountdownArtRabbit03', 'art-rabbit'), ('CountdownArtCat02', 'art-cat'),
                         ('CountdownArtPair06', 'art-together')]:
        shutil.copy2(ROOT / f'App/Assets.xcassets/{source}.imageset/illustration.png', ASSETS / f'{name}.png')
print('Exported current promotion assets. Run swift scripts/render_promotion.swift.')
