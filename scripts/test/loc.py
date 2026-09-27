#!/usr/bin/env python3
"""Lists localization keys missing from the catalog, or adds ru translations from a JSON file."""
import json, glob, sys
CATALOG = 'OriCmd/Localizable.xcstrings'
catalog = json.load(open(CATALOG))
if len(sys.argv) > 1:
    for key, value in json.load(open(sys.argv[1])).items():
        catalog['strings'][key] = {"localizations": {"ru": {"stringUnit": {"state": "translated", "value": value}}}}
    json.dump(catalog, open(CATALOG, 'w'), ensure_ascii=False, indent=2, sort_keys=True)
keys = set()
for f in glob.glob('build/DerivedData/**/*.stringsdata', recursive=True):
    for entries in json.load(open(f)).get('tables', {}).values():
        keys.update(e['key'] for e in entries)
missing = sorted(k for k in keys if k not in catalog['strings'])
print(json.dumps(missing, ensure_ascii=False, indent=1))
