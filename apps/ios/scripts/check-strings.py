#!/usr/bin/env python3
"""Fails the build when a string the app shows has no Russian, or a Russian that drops or changes
a placeholder (apps/ios/docs/ROADMAP.md, 3.3). Xcode itself only marks such a string as needing
work, and only its editor adds a new string to the catalog, so a string the compiler found in the
code but the catalog lacks fails too, at the line that uses it. Run by the app target's "Check
translations" build phase after the sources compile; messages use Xcode's `file:line: error:` form.
Usage: check-strings.py <catalog.xcstrings> <compiler's Objects-normal directory> [<catalog.xcstrings>...]
The catalogs after the directory (InfoPlist.xcstrings, the permission prompts) are checked for
their translations only: the compiler doesn't report Info.plist keys as used.
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


def units(localization, path=()):
    """{path: stringUnit} in one language's localization: the plain one at (), and each plural or
    device form under `variations` at its path, ('plural', 'one') and so on."""
    out = {}
    if 'stringUnit' in localization:
        out[path] = localization['stringUnit']
    for kind, forms in localization.get('variations', {}).items():
        for form, inner in forms.items():
            out.update(units(inner, path + (kind, form)))
    return out


def untranslated(catalog):
    """(key, problem) for each catalog string whose translation is missing or wrong."""
    out = []
    source = catalog.get('sourceLanguage', 'en')
    for key, entry in sorted(catalog.get('strings', {}).items()):
        if entry.get('shouldTranslate') is False:
            continue
        locs = entry.get('localizations', {})
        base = units(locs.get(source, {}))
        for lang in LANGUAGES:
            translated = units(locs.get(lang, {}))
            if not translated:
                out.append((key, f'"{key}" has no {lang} translation'))
                continue
            for path, unit in sorted(translated.items()):
                form = f' ({" ".join(path)})' if path else ''
                if unit.get('state') != 'translated' or not unit.get('value', '').strip():
                    out.append((key, f'"{key}"{form} has no {lang} translation'))
                    continue
                # A plural form's source is the same form, else the plain string, else the key.
                source_unit = base.get(path) or base.get(()) or {'value': key}
                if placeholders(unit['value']) != placeholders(source_unit.get('value', key)):
                    out.append((key, f'"{key}"{form}: the {lang} translation\'s placeholders differ from the source\'s'))
    return out


def current(source, compiled):
    """Whether a .stringsdata file's strings are this build's. The objects directory keeps files
    from earlier builds: a source since deleted or renamed has one there still, and its strings
    would count as used. A Swift source counts only if this build compiled it (compiled, the
    architecture's SwiftFileList, or None without one); generated metadata such as
    ExtractedAppShortcutsMetadata has no Swift source and always counts."""
    return not source.endswith('.swift') or compiled is None or source in compiled


def compiled_sources(directory):
    """The Swift sources an architecture's build compiled, from its *.SwiftFileList files (one
    path a line, a space possibly escaped), or None without one."""
    lists = sorted(glob.glob(os.path.join(directory, '*.SwiftFileList')))
    if not lists:
        return None
    out = set()
    for path in lists:
        with open(path) as f:
            out.update(line.strip().replace('\\ ', ' ') for line in f if line.strip())
    return out


def used(objects_dir, archs=None):
    """{key: (source file, line)} for every string the compiler found for the table, in this
    build's architectures (archs, else every one there): an architecture built before keeps its
    directory, with the strings the code had then."""
    out = {}
    if not os.path.isdir(objects_dir):
        return out
    names = archs if archs else sorted(n for n in os.listdir(objects_dir) if os.path.isdir(os.path.join(objects_dir, n)))
    for arch in names:
        directory = os.path.join(objects_dir, arch)
        compiled = compiled_sources(directory)
        for path in sorted(glob.glob(os.path.join(directory, '*.stringsdata'))):
            with open(path) as f:
                data = json.load(f)
            # A file naming no source can't be matched to this build: it counts only without a list.
            if 'source' not in data:
                if compiled is None:
                    source = path
                else:
                    continue
            else:
                source = data['source']
            if not current(source, compiled):
                continue
            for s in data.get('tables', {}).get(TABLE, []):
                out.setdefault(s['key'], (source, s.get('location', {}).get('startingLine', 1)))
    return out


def main():
    catalog_path, objects_dir, more = sys.argv[1], sys.argv[2], sys.argv[3:]
    with open(catalog_path) as f:
        catalog = json.load(f)
    keys = catalog.get('strings', {})
    errors = []
    # Xcode sets ARCHS for the build phase: the architectures this build compiles.
    archs = os.environ.get('ARCHS', '').split() or None
    for key, (source, line) in sorted(used(objects_dir, archs).items()):
        if key not in keys:
            errors.append(f'{source}:{line}: error: "{key}" isn\'t in {os.path.basename(catalog_path)}; add it with its ru translation')
    for path in [catalog_path, *more]:
        with open(path) as f:
            for _, problem in untranslated(json.load(f)):
                errors.append(f'{path}:1: error: {problem}')
    for e in errors:
        print(e)
    sys.exit(1 if errors else 0)


if __name__ == '__main__':
    main()
