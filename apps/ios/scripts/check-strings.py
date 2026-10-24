#!/usr/bin/env python3
"""Fails the build when a string the app shows has no Russian, or a Russian that drops or changes
a placeholder (apps/ios/docs/ROADMAP.md, 3.3). Xcode itself only marks such a string as needing
work, and only its editor adds a new string to the catalog, so a string the compiler found in the
code but the catalog lacks fails too, at the line that uses it. Run by the app target's "Check
translations" build phase after the sources compile; messages use Xcode's `file:line: error:` form.
Usage: check-strings.py <catalog.xcstrings> <compiler's Objects-normal directory>
"""
import glob
import json
import os
import re
import sys

LANGUAGES = ['ru']
TABLE = 'Localizable'
PLACEHOLDER = re.compile(r'%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:ll|l|h)?[@dDuUxXoOfeEgGcCsSaAp]')


def placeholders(text):
    return sorted(PLACEHOLDER.findall(text))


def untranslated(catalog):
    """(key, problem) for each catalog string whose translation is missing or wrong."""
    out = []
    source = catalog.get('sourceLanguage', 'en')
    for key, entry in sorted(catalog.get('strings', {}).items()):
        if entry.get('shouldTranslate') is False:
            continue
        locs = entry.get('localizations', {})
        base = locs.get(source, {}).get('stringUnit', {}).get('value', key)
        for lang in LANGUAGES:
            unit = locs.get(lang, {}).get('stringUnit')
            if not unit or unit.get('state') != 'translated' or not unit.get('value', '').strip():
                out.append((key, f'"{key}" has no {lang} translation'))
            elif placeholders(unit['value']) != placeholders(base):
                out.append((key, f'"{key}": the {lang} translation\'s placeholders differ from the source\'s'))
    return out


def used(objects_dir):
    """{key: (source file, line)} for every string the compiler found for the table."""
    out = {}
    for path in sorted(glob.glob(os.path.join(objects_dir, '*', '*.stringsdata'))):
        with open(path) as f:
            data = json.load(f)
        for s in data.get('tables', {}).get(TABLE, []):
            out.setdefault(s['key'], (data.get('source', path), s.get('location', {}).get('startingLine', 1)))
    return out


def main():
    catalog_path, objects_dir = sys.argv[1], sys.argv[2]
    with open(catalog_path) as f:
        catalog = json.load(f)
    keys = catalog.get('strings', {})
    errors = []
    for key, (source, line) in sorted(used(objects_dir).items()):
        if key not in keys:
            errors.append(f'{source}:{line}: error: "{key}" isn\'t in {os.path.basename(catalog_path)}; add it with its ru translation')
    for _, problem in untranslated(catalog):
        errors.append(f'{catalog_path}:1: error: {problem}')
    for e in errors:
        print(e)
    sys.exit(1 if errors else 0)


if __name__ == '__main__':
    main()
