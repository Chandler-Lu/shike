#!/usr/bin/env python3
"""Local release checks. --submission also checks published pages and manual release evidence."""
import argparse
import json
import plistlib
import re
import struct
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
errors = []


def check(ok, message):
    print(('PASS ' if ok else 'FAIL ') + message)
    if not ok:
        errors.append(message)


def plist(path):
    with Path(path).open('rb') as f:
        return plistlib.load(f)


def png_info(path):
    data = Path(path).read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        return None
    width, height = struct.unpack('>II', data[16:24])
    has_alpha = data[25] in (4, 6)
    pos = 8
    while pos + 12 <= len(data):
        size = struct.unpack('>I', data[pos:pos + 4])[0]
        if data[pos + 4:pos + 8] == b'tRNS':
            has_alpha = True
        pos += size + 12
    return width, height, has_alpha


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--submission', action='store_true')
    args = parser.parse_args()
    project = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(ROOT / 'Shike.xcodeproj/project.pbxproj')]))
    objects = project['objects']
    targets = [v for v in objects.values() if v.get('isa') == 'PBXNativeTarget']
    versions, teams = set(), set()
    for target in targets:
        configs = objects[target['buildConfigurationList']]['buildConfigurations']
        for config in configs:
            item = objects[config]; settings = item['buildSettings']
            expected_family = '4' if target['name'].startswith('ShikeWatch') else '1'
            check(str(settings.get('TARGETED_DEVICE_FAMILY')) == expected_family, f"{target['name']} {item['name']}: expected device family {expected_family}")
            versions.add((str(settings['MARKETING_VERSION']), str(settings['CURRENT_PROJECT_VERSION'])))
            teams.add(settings.get('DEVELOPMENT_TEAM'))
        if target['name'] in ('Shike', 'ShikeShare'):
            paths = set()
            for phase in target['buildPhases']:
                for build in objects[phase].get('files', []):
                    ref = objects[build].get('fileRef')
                    if ref:
                        paths.add(objects[ref].get('path'))
            check({'Shared/Resources/PrivacyInfo.xcprivacy', 'Shared/Resources/PrivacyPolicy.txt', 'Shared/Resources/Fonts/OFL.txt',
                   'Shared/Services/PrivacyConsent.swift', 'Shared/UI/PrivacyViews.swift'} <= paths, f"{target['name']}: consent and legal resources included")
    check(len(versions) == 1, 'App, extension and tests use one version/build')
    check(len(teams) == 1 and None not in teams and '' not in teams, 'All targets use the same explicit signing team')
    export = plist(ROOT / 'Config/ExportOptions-AppStore.plist')
    check(export['teamID'] in teams and export['method'] == 'app-store-connect' and export['destination'] == 'export', 'Export options match the team and do not upload')
    for name in ('App', 'Share'):
        info = plist(ROOT / f'Config/{name}-Info.plist')
        target_name = 'Shike' if name == 'App' else 'ShikeShare'
        target = next(t for t in targets if t['name'] == target_name)
        build_declarations = [objects[c]['buildSettings'].get('INFOPLIST_KEY_ITSAppUsesNonExemptEncryption')
                              for c in objects[target['buildConfigurationList']]['buildConfigurations']]
        check(info.get('ITSAppUsesNonExemptEncryption') is False or all(v in ('NO', False) for v in build_declarations),
              f'{name}: exempt encryption declaration')
    app_entitlements = plist(ROOT / 'Config/ShikeApp.entitlements')
    share_entitlements = plist(ROOT / 'Config/Shike.entitlements')
    check(set(app_entitlements.get('com.apple.developer.icloud-services', [])) == {'CloudKit', 'CloudDocuments'}, 'Main app: CloudKit and iCloud Drive declared')
    check(app_entitlements.get('com.apple.developer.ubiquity-container-identifiers') == ['$(SHIKE_CLOUD_CONTAINER)'], 'Main app: iCloud Drive backup container')
    companion = plist(ROOT / 'Config/CountdownCompanion.entitlements')
    check(companion.get('com.apple.security.application-groups') == ['$(SHIKE_APP_GROUP)'], 'Companions: shared display data group')
    check('com.apple.developer.icloud-services' not in companion and 'keychain-access-groups' not in companion, 'Companions: no CloudKit or API key access')
    check({'ShikeWidgets', 'ShikeWatch', 'ShikeWatchWidgets'} <= {t['name'] for t in targets}, 'Widget and Watch targets exist')
    check(app_entitlements.get('com.apple.developer.icloud-container-identifiers') == ['$(SHIKE_CLOUD_CONTAINER)'], 'Main app: explicit CloudKit container')
    check(app_entitlements.get('aps-environment') == '$(APS_ENVIRONMENT)', 'Main app: APNs entitlement')
    check(app_entitlements.get('com.apple.developer.icloud-container-environment') == '$(SHIKE_CLOUD_ENVIRONMENT)', 'Main app: explicit CloudKit environment')
    development = plist(ROOT / 'Config/ExportOptions-Development.plist')
    check(development.get('method') == 'debugging' and development.get('iCloudContainerEnvironment') == 'Development', 'Development export: Development CloudKit environment')
    check(export.get('iCloudContainerEnvironment') == 'Production', 'App Store export: Production CloudKit environment')
    check('com.apple.developer.icloud-services' not in share_entitlements, 'Share extension: no countdown CloudKit access')
    check('remote-notification' in plist(ROOT / 'Config/App-Info.plist').get('UIBackgroundModes', []), 'CloudKit background notification mode')
    check((ROOT / 'Schemas/Export/shike-export-v1.schema.json').exists(), 'Versioned JSON export schema provided')
    manifest = plist(ROOT / 'Shared/Resources/PrivacyInfo.xcprivacy')
    check(manifest['NSPrivacyTracking'] is False and not manifest['NSPrivacyTrackingDomains'], 'No tracking declared')
    check(set(manifest['NSPrivacyAccessedAPITypes'][0]['NSPrivacyAccessedAPITypeReasons']) == {'CA92.1', '1C8F.1'}, 'UserDefaults private and app-group required reasons')
    check(png_info(ROOT / 'App/Assets.xcassets/AppIcon.appiconset/AppIcon.png') == (1024, 1024, False), 'App icon: opaque 1024 x 1024')

    metadata = json.loads((ROOT / 'docs/app-store/metadata/zh-Hans.json').read_text())
    check(metadata['name'] == '拾刻计划', 'Store metadata uses the current product name')
    for target in targets:
        if target['name'] in ('Shike', 'ShikeShare', 'ShikeWidgets', 'ShikeWatch', 'ShikeWatchWidgets'):
            names = [objects[c]['buildSettings'].get('INFOPLIST_KEY_CFBundleDisplayName')
                     for c in objects[target['buildConfigurationList']]['buildConfigurations']]
            check(all(name == metadata['name'] for name in names), f"{target['name']}: display name matches store metadata")
    for key, limit in [('name', 30), ('subtitle', 30), ('description', 4000), ('promotional_text', 170), ('release_notes', 4000)]:
        check(0 < len(metadata[key]) <= limit, f'Metadata {key}: within {limit} characters')
    check(len(metadata['keywords'].encode('utf-8')) <= 100, 'Keywords within 100 UTF-8 bytes')
    shots = sorted((ROOT / 'docs/app-store/screenshots/zh-Hans').glob('*.jpg'))
    check(len(shots) == 8, 'Eight App Store screenshots')
    for shot in shots:
        info = subprocess.check_output(['sips', '-g', 'pixelWidth', '-g', 'pixelHeight', '-g', 'hasAlpha', str(shot)], text=True)
        check('pixelWidth: 1320' in info and 'pixelHeight: 2868' in info and 'hasAlpha: no' in info, f'{shot.name}: 1320 x 2868, opaque')
    watch_shots = sorted((ROOT / 'docs/app-store/screenshots/watch-zh-Hans').glob('*.jpg'))
    check(len(watch_shots) == 3, 'Three Apple Watch App Store screenshots')
    for shot in watch_shots:
        info = subprocess.check_output(['sips', '-g', 'pixelWidth', '-g', 'pixelHeight', '-g', 'hasAlpha', str(shot)], text=True)
        check('pixelWidth: 368' in info and 'pixelHeight: 448' in info and 'hasAlpha: no' in info, f'{shot.name}: 368 x 448, opaque')
    tracked = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=ROOT).decode().split('\0')
    unsafe = []
    for relative in filter(None, tracked):
        path = ROOT / relative
        if not path.is_file():
            continue
        if re.search(r'(^|/)(build|\.build|xcuserdata)/|Local\.xcconfig$|\.(p12|p8|mobileprovision|ipa|store)$', relative):
            unsafe.append(relative)
        # Report file names only. Never print matches that may contain a credential.
        if re.search(rb'sk-(?:proj-|ant-)?[A-Za-z0-9_-]{24,}|AIza[A-Za-z0-9_-]{30,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----', path.read_bytes()):
            unsafe.append(relative)
    check(not unsafe, 'Source files have no local signing/runtime files or common secret patterns' + (': ' + ', '.join(unsafe) if unsafe else ''))
    if args.archive:
        archive = args.archive.resolve()
        app = archive / 'Products/Applications/Shike.app'
        for bundle in (app, app / 'PlugIns/ShikeShare.appex', app / 'PlugIns/ShikeWidgets.appex',
                       app / 'Watch/ShikeWatch.app', app / 'Watch/ShikeWatch.app/PlugIns/ShikeWatchWidgets.appex'):
            check(bundle.is_dir(), f'Archive bundle exists: {bundle.name}')
            if not bundle.is_dir():
                continue
            info = plist(bundle / 'Info.plist')
            check(info.get('UIDeviceFamily') == ([4] if 'ShikeWatch' in bundle.name else [1]), f'{bundle.name}: expected device family')
            check((info['CFBundleShortVersionString'], info['CFBundleVersion']) in versions, f'{bundle.name}: expected version/build')
            check(info.get('ITSAppUsesNonExemptEncryption') is False, f'{bundle.name}: encryption declaration')
            resources = ['PrivacyInfo.xcprivacy', 'OFL.txt', 'LXGWWenKai-Regular.ttf']
            if bundle in (app, app / 'PlugIns/ShikeShare.appex'):
                resources.append('PrivacyPolicy.txt')
            for resource in resources:
                check((bundle / resource).is_file(), f'{bundle.name}: {resource}')
            binary = (bundle / info['CFBundleExecutable']).read_bytes()
            check(not any(marker in binary for marker in (b'debugFixtureModelExpiry', b'debugFixtureConsentExpiry', b'-review-fixture', b'-seed-example', b'-share-fixture', b'-store-screenshots', b'-countdown-fixture', b'-calendar-denied-fixture', b'-calendar-fixture', b'-planning-fixture', b'-cloudkit-diagnose-readonly', b'-cloudkit-diagnose-sync', b'-cloudkit-diagnose-schema', b'-watch-fixture', b'-watch-reset-group', b'-companion-fixture')), f'{bundle.name}: debug fixture entry points absent')
        if args.submission and app.is_dir():
            verified = subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], capture_output=True)
            check(verified.returncode == 0, 'Archive code signature verifies (distribution eligibility still requires Organizer validation)')
    if args.submission:
        check(args.archive is not None, 'Submission check includes a signed archive')
        ready = json.loads((ROOT / 'docs/app-store/readiness.json').read_text())
        for item in ready['manual_checks']:
            check(item['complete'] is True and bool(item.get('evidence', '').strip()), item['title'])
        for key, phrase in [('privacy_url', metadata['name'] + '隐私政策'), ('support_url', metadata['name'] + '支持')]:
            try:
                with urllib.request.urlopen(metadata[key], timeout=15) as response:
                    content = response.read(1_000_000).decode('utf-8')
                    check(response.status == 200 and phrase in content and 'trlu1997@outlook.com' in content, f'Published {key} is reachable and has expected content')
            except Exception as error:
                check(False, f'Published {key}: {type(error).__name__}')
    print(f'\n{len(errors)} failed check(s). ' + ('Local preparation verified; this does not certify App Store acceptance.' if not errors else 'Resolve failures before the corresponding release step.'))
    return bool(errors)


if __name__ == '__main__':
    sys.exit(main())
