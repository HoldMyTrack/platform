#!/usr/bin/env python3
"""Writes the iOS app's share of the visual language from the files that define it, so nothing
is copied by hand (apps/ios/docs/ROADMAP.md, 3.2):

- the palette, light and dark, from the web's tokens.css as named colors in the asset catalog;
- the spacing, radius and type scales from the same file as HoldMyTrack/DesignTokens.swift;
- the icons from the Android app's Lucide vector drawables, as template SVGs, with Lucide's
  license, which the app ships as Android's does;
- the fonts, Inter, Fraunces and Source Serif 4, the same files the Android app bundles.

`--check` writes nothing and fails when any of it differs from what is committed; CI runs it.
Usage, from anywhere: apps/ios/scripts/make-design.py [--check]
"""
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
TOKENS = os.path.join(ROOT, 'services/server/internal/web/static/tokens.css')
DRAWABLES = os.path.join(ROOT, 'apps/android/holdmytrack/app/src/main/res/drawable')
APP = os.path.join(ROOT, 'apps/ios/HoldMyTrack')
PALETTE = os.path.join(APP, 'Assets.xcassets/Palette')
ICONS = os.path.join(APP, 'Assets.xcassets/Icons')
SWIFT = os.path.join(APP, 'DesignTokens.swift')
ANDROID_FONTS = os.path.join(ROOT, 'apps/android/holdmytrack/app/src/main/res/font')
FONTS = os.path.join(APP, 'Fonts')
FONT_FILES = ['inter.ttf', 'fraunces.ttf', 'source_serif_4.ttf']
ANDROID_LUCIDE_LICENSE = os.path.join(ROOT, 'apps/android/holdmytrack/app/src/main/assets/licenses/lucide-LICENSE.txt')
LICENSES = os.path.join(APP, 'Licenses')

# Drawables that aren't one-color Lucide-style icons: the sign-in brand marks keep their own
# colors, the bottom bar's empty spacer is a shape, and the record dot is a filled signal red.
SKIP_ICONS = {'ic_brand_facebook', 'ic_brand_google', 'ic_nav_gap', 'ic_record_start'}
ANDROID = '{http://schemas.android.com/apk/res/android}'
CATALOG_INFO = {'author': 'xcode', 'version': 1}


def blocks(css):
    """The light :root block and the data-theme='dark' one, as {name: value}."""
    def parse(body):
        return dict(re.findall(r'--fm-([a-z0-9-]+):\s*([^;]+);', body))
    light = re.search(r':root\s*\{(.*?)\n\}', css, re.S).group(1)
    dark = re.search(r":root\[data-theme='dark'\]\s*\{(.*?)\n\}", css, re.S).group(1)
    return parse(light), parse(dark)


def rgba(value):
    """A token's color as (r, g, b, alpha) in 0–255 and 0–1, or None for a non-color token."""
    value = value.strip()
    m = re.fullmatch(r'#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})', value)
    if m:
        h = m.group(1)
        if len(h) == 3:
            h = ''.join(c * 2 for c in h)
        return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), 1.0
    m = re.fullmatch(r'rgb\((\d+) (\d+) (\d+) / (\d+)%\)', value)
    if m:
        return int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4)) / 100
    return None


def colorset(light, dark):
    def entry(c, appearance):
        e = {'color': {'color-space': 'srgb', 'components': {
            'red': f'0x{c[0]:02X}', 'green': f'0x{c[1]:02X}', 'blue': f'0x{c[2]:02X}', 'alpha': f'{c[3]:.3f}'}},
            'idiom': 'universal'}
        if appearance:
            e['appearances'] = [{'appearance': 'luminosity', 'value': appearance}]
        return e
    return {'colors': [entry(light, None), entry(dark, 'dark')], 'info': CATALOG_INFO}


def palette(css):
    """{colorset name: Contents.json} for every color token both palettes define."""
    light, dark = blocks(css)
    out = {}
    for name, value in light.items():
        lc, dc = rgba(value), rgba(dark.get(name, value))
        if lc and dc:
            out[name] = colorset(lc, dc)
    return out


def camel(name):
    head, *rest = name.split('-')
    return head + ''.join(p[:1].upper() + p[1:] for p in rest)


def swift_name(key):
    """A scale step as a Swift name: 8 becomes s8, 2xs becomes xxs, sm stays sm."""
    m = re.fullmatch(r'(\d)(x[sl])', key)
    if m:
        return 'x' * int(m.group(1)) + m.group(2)[1]
    return f's{key}' if key.isdigit() else camel(key)


def swift_tokens(css):
    light, _ = blocks(css)

    def scale(prefix, unit):
        items = [(k[len(prefix):], v.strip()) for k, v in light.items() if k.startswith(prefix)]
        return [(swift_name(k), v[:-len(unit)] if unit and v.endswith(unit) else v) for k, v in items]

    def enum(name, doc, rows):
        lines = [f'    /// {doc}', f'    enum {name} {{']
        lines += [f'        static let {k}: CGFloat = {v}' for k, v in rows]
        lines.append('    }')
        return lines

    lines = [
        '// Written by apps/ios/scripts/make-design.py from the web\'s tokens.css; edit that file',
        '// and run the script. The colors are the asset catalog\'s Palette folder.',
        '',
        'import CoreGraphics',
        '',
        '/// The web\'s spacing, radius and type scales, in points.',
        'enum DesignTokens {',
    ]
    lines += enum('Space', 'fm-space-*.', scale('space-', 'px'))
    lines += enum('Radius', 'fm-radius-*; pill is any value past half a control\'s height.', scale('radius-', 'px'))
    lines += enum('Text', 'fm-text-*, before Dynamic Type scales them.', scale('text-', 'px'))
    lines += enum('Weight', 'fm-weight-*, as variable-font weights.', scale('weight-', ''))
    lines.append('}')
    return '\n'.join(lines) + '\n'


def svg(path):
    """An Android vector drawable as a one-color SVG, or None for anything else."""
    root = ET.parse(path).getroot()
    if root.tag != 'vector':
        return None
    w, h = root.get(ANDROID + 'viewportWidth'), root.get(ANDROID + 'viewportHeight')
    paths = []
    for p in root.iter('path'):
        attrs = [f'd="{p.get(ANDROID + "pathData")}"']
        attrs.append('fill="#000"' if p.get(ANDROID + 'fillColor') else 'fill="none"')
        if p.get(ANDROID + 'strokeColor'):
            attrs.append('stroke="#000"')
            for a, s in (('strokeWidth', 'stroke-width'), ('strokeLineCap', 'stroke-linecap'), ('strokeLineJoin', 'stroke-linejoin')):
                if p.get(ANDROID + a):
                    attrs.append(f'{s}="{p.get(ANDROID + a)}"')
        paths.append(f'  <path {" ".join(attrs)}/>')
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 {w} {h}">\n'
            + '\n'.join(paths) + '\n</svg>\n')


def icons():
    """{imageset name: (svg text, Contents.json)} for every Lucide-style drawable."""
    out = {}
    for f in sorted(os.listdir(DRAWABLES)):
        base, ext = os.path.splitext(f)
        if ext != '.xml' or not base.startswith('ic_') or base in SKIP_ICONS:
            continue
        text = svg(os.path.join(DRAWABLES, f))
        if text is None:
            continue
        name = base[3:].replace('_', '-')
        out[name] = (text, {'images': [{'filename': f'{name}.svg', 'idiom': 'universal'}], 'info': CATALOG_INFO,
                            'properties': {'preserves-vector-representation': True, 'template-rendering-intent': 'template'}})
    return out


def wanted():
    """{path: text} of every file the script owns."""
    css = open(TOKENS).read()
    files = {SWIFT: swift_tokens(css)}
    for name in FONT_FILES:
        files[os.path.join(FONTS, name)] = open(os.path.join(ANDROID_FONTS, name), 'rb').read()
    files[os.path.join(LICENSES, 'lucide-LICENSE.txt')] = open(ANDROID_LUCIDE_LICENSE, 'rb').read()
    folder = {'info': CATALOG_INFO, 'properties': {'provides-namespace': False}}
    files[os.path.join(PALETTE, 'Contents.json')] = json.dumps(folder, indent=2) + '\n'
    for name, contents in palette(css).items():
        files[os.path.join(PALETTE, f'{name}.colorset', 'Contents.json')] = json.dumps(contents, indent=2) + '\n'
    files[os.path.join(ICONS, 'Contents.json')] = json.dumps(folder, indent=2) + '\n'
    for name, (text, contents) in icons().items():
        files[os.path.join(ICONS, f'{name}.imageset', f'{name}.svg')] = text
        files[os.path.join(ICONS, f'{name}.imageset', 'Contents.json')] = json.dumps(contents, indent=2) + '\n'
    return files


def existing():
    out = set()
    for folder in (PALETTE, ICONS, FONTS, LICENSES):
        for dirpath, _, names in os.walk(folder):
            out.update(os.path.join(dirpath, n) for n in names)
    return out


def read(path, like):
    """path's content as bytes or text, whichever like is."""
    with open(path, 'rb' if isinstance(like, bytes) else 'r') as f:
        return f.read()


def main():
    check = '--check' in sys.argv[1:]
    files = wanted()
    stale = sorted(existing() - set(files))
    changed = sorted(p for p, data in files.items() if not os.path.exists(p) or read(p, data) != data)
    if check:
        for p in changed + stale:
            print('make-design: out of date:', os.path.relpath(p, ROOT))
        if changed or stale:
            print('make-design: run apps/ios/scripts/make-design.py and commit what it writes')
            sys.exit(1)
        return
    for p in stale:
        os.remove(p)
    for p in changed:
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, 'wb' if isinstance(files[p], bytes) else 'w') as f:
            f.write(files[p])
    for folder in (PALETTE, ICONS):
        for dirpath, dirs, names in os.walk(folder, topdown=False):
            if not dirs and not names:
                os.rmdir(dirpath)
    print(f'make-design: {len(changed)} written, {len(stale)} removed')


if __name__ == '__main__':
    main()
