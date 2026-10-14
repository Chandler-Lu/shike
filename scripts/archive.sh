#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-unsigned}"
case "$mode" in unsigned|signed|export|export-development) ;; *) echo 'Usage: scripts/archive.sh [unsigned|signed|export|export-development] [archive-path]' >&2; exit 2 ;; esac
mkdir -p build/release
if [[ "$mode" == export || "$mode" == export-development ]]; then
    archive_path="${2:-build/release/Shike-signed.xcarchive}"
    [[ -d "$archive_path" ]] || { echo 'Run scripts/archive.sh signed first.' >&2; exit 1; }
    export_options=Config/ExportOptions-AppStore.plist
    export_path=build/release/export
    if [[ "$mode" == export-development ]]; then
        export_options=Config/ExportOptions-Development.plist
        export_path=build/release/export-development
    fi
    [[ ! -e "$export_path" ]] || { echo "Export exists: $export_path. Move it before exporting again." >&2; exit 1; }
    xcodebuild -exportArchive -archivePath "$archive_path" \
        -exportOptionsPlist "$export_options" -exportPath "$export_path"
    exit
fi
archive_path="build/release/Shike-${mode}.xcarchive"
[[ ! -e "$archive_path" ]] || { echo "Archive exists: $archive_path. Move it before creating another archive." >&2; exit 1; }
archive_command=(xcodebuild -project Shike.xcodeproj -scheme Shike -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath build/release/DerivedData \
    -archivePath "$archive_path" archive)
if [[ "$mode" == unsigned ]]; then archive_command+=(CODE_SIGNING_ALLOWED=NO); fi
"${archive_command[@]}"
python3 scripts/release_preflight.py --archive "$archive_path"
if [[ "$mode" == unsigned ]]; then
    echo 'Unsigned archive validated for contents only. It cannot be installed or submitted.'
else
    echo 'Signed archive created. Validate it in Xcode Organizer before exporting or uploading.'
fi
