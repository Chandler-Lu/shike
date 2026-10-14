#!/usr/bin/env python3
"""Validate a Shike JSON export (requires jsonschema >= 4.18). Does not print user content."""
import argparse
import json
from pathlib import Path
from jsonschema import Draft202012Validator, FormatChecker

ROOT = Path(__file__).resolve().parent.parent

def validate(path):
    schema = json.loads((ROOT / 'Schemas/Export/shike-export-v1.schema.json').read_text(encoding='utf-8'))
    Draft202012Validator.check_schema(schema)
    data = json.loads(path.read_text(encoding='utf-8'))
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    errors = list(validator.iter_errors(data))
    if errors:
        # Schema errors can embed raw field values; report paths only.
        locations = ', '.join('/'.join(map(str, error.absolute_path)) or '/' for error in errors[:10])
        raise ValueError('Schema mismatch at: ' + locations)
    for collection in ('countdowns', 'countdownCategories', 'apiProfiles', 'importSessions'):
        ids = [item['id'] for item in data[collection]]
        if len(ids) != len(set(ids)):
            raise ValueError('Duplicate IDs in ' + collection)
    categories = {c['id'] for c in data['countdownCategories']}
    if any(c.get('categoryID') and c['categoryID'] not in categories for c in data['countdowns']):
        raise ValueError('Unresolved countdown category reference')
    profiles = {p['id'] for p in data['apiProfiles']}
    active = data['preferences']['activeProfileID']
    if active and active not in profiles:
        raise ValueError('Unresolved active API profile')
    for item in data['countdowns']:
        if (item['calendar'] == 'chinese') != ('lunarDate' in item):
            raise ValueError('Lunar date is required only for the Chinese calendar')
    print('PASS: schema v1, RFC 3339 timestamps, civil dates, unique IDs and references')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('file', type=Path, nargs='?', default=ROOT / 'Schemas/Export/example-v1.json')
    args = parser.parse_args()
    validate(args.file)
