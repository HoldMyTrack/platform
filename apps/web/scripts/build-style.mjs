/**
 * Emits one style document per language and flavor, and one layers template per flavor, for the
 * API to serve (ARCHITECTURE.md §2.1: "Serve the style as a document from the API rather than
 * reimplementing it per client"). The language is the labels' (`buildStyle`'s `lang`), one per
 * catalog in `src/i18n`; the layers document (`mapLayers.ts`) has no labels of its own.
 *
 * Generating rather than hand-writing these is the whole point: `buildStyle()` and
 * `buildLayers()` stay the single definitions, and a Go reimplementation of 71 layers is exactly
 * the divergence `ARCHITECTURE.md` §2.1 exists to prevent. The `.json` files this writes are
 * build output, not a second source — edit `src/map/` and re-run; never edit the JSON.
 *
 * `origin` is baked as a placeholder rather than a real host because one built artifact has
 * to serve every deployment: dev reads the archive from the app's own origin, production may
 * read it from a CDN (`VITE_BASEMAP_ORIGIN`, `config.ts`'s `basemapOrigin()`). The server
 * substitutes its own configured origin per request, and the account's tile version into the
 * layers template the same way.
 *
 * The satellite imagery source is a placeholder for the same reason, and more so: its tile URL
 * carries a deployment's own key. The server fills it from `SATELLITE_*`, or strips the source,
 * its layer and the hidden-layer list when a deployment configures no imagery (mapstyle.go).
 *
 * Every document carries the same `styleBuild`, a hash over all of them, so a client holding a
 * style and a layers document from different builds can tell.
 *
 * Usage: node scripts/build-style.mjs [--check]
 *   --check regenerates in memory and fails if the committed files differ, so drift between
 *   src/map/ and the served documents is caught here rather than on a client.
 */
import { createHash } from 'node:crypto';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { registerHooks } from 'node:module';
import { dirname, join, resolve as resolvePath } from 'node:path';
import { fileURLToPath } from 'node:url';

// src/ imports are extensionless by convention (Vite resolves them; Node does not). Rather
// than write `./config.ts` into production source for this script's benefit, retry a failed
// relative resolve with the extension Node needs.
registerHooks({
  resolve(specifier, context, nextResolve) {
    try {
      return nextResolve(specifier, context);
    } catch (err) {
      if (specifier.startsWith('.') && !/\.[cm]?[jt]s$/.test(specifier)) {
        return nextResolve(`${specifier}.ts`, context);
      }
      throw err;
    }
  },
});

const { basemapLabelIds, buildStyle, FLAVORS, isDarkFlavor, STYLE_BUILD_METADATA } = await import('../src/map/style.ts');
const { buildLayers } = await import('../src/map/mapLayers.ts');
const { LANGS } = await import('../src/i18n/index.ts');

/** Must match originPlaceholder in services/server/internal/mapstyle/mapstyle.go. */
const ORIGIN_PLACEHOLDER = '__HOLDMYTRACK_BASEMAP_ORIGIN__';

/** Must match satelliteTilesPlaceholder and satelliteAttributionPlaceholder in mapstyle.go. */
const SATELLITE_PLACEHOLDER = {
  tiles: '__HOLDMYTRACK_SATELLITE_TILES__',
  tileSize: 512,
  maxzoom: 18,
  attribution: '__HOLDMYTRACK_SATELLITE_ATTRIBUTION__',
};

/** Must match tileVersionPlaceholder in mapstyle.go. */
const TILE_VERSION_PLACEHOLDER = '__HOLDMYTRACK_TILE_VERSION__';

const here = dirname(fileURLToPath(import.meta.url));
const outDir = resolvePath(here, '../../../services/server/internal/mapstyle');
const check = process.argv.includes('--check');
let drifted = false;

/** Every document by its path under outDir, before the build hash goes in. */
const docs = new Map();
for (const lang of LANGS) {
  for (const flavor of FLAVORS) {
    docs.set(`styles/${lang}/${flavor}.json`, buildStyle({ flavor, origin: ORIGIN_PLACEHOLDER, satellite: SATELLITE_PLACEHOLDER, lang }));
  }
}
for (const flavor of FLAVORS) {
  // Fog mutes the labels by id, so every language has to give them the same ones.
  const labelIds = basemapLabelIds(flavor);
  for (const lang of LANGS) {
    const ids = docs.get(`styles/${lang}/${flavor}.json`).layers.filter((layer) => layer.type === 'symbol').map((layer) => layer.id);
    if (JSON.stringify(ids) !== JSON.stringify(labelIds)) throw new Error(`${lang}/${flavor}: label layer ids differ from English`);
  }
  docs.set(`layers/${flavor}.json`, buildLayers({ flavor, dark: isDarkFlavor(flavor), labelIds, tileVersion: TILE_VERSION_PLACEHOLDER }));
}

const hash = createHash('sha256');
for (const [name, doc] of [...docs].sort(([a], [b]) => a.localeCompare(b))) hash.update(name).update(JSON.stringify(doc));
const styleBuild = hash.digest('hex').slice(0, 12);

for (const [name, doc] of docs) {
  if (name.startsWith('styles/')) doc.metadata = { ...doc.metadata, [STYLE_BUILD_METADATA]: styleBuild };
  else doc.styleBuild = styleBuild;
  const json = `${JSON.stringify(doc, null, 2)}\n`;
  const path = join(outDir, name);

  if (check) {
    const existing = await readFile(path, 'utf8').catch(() => null);
    if (existing !== json) {
      console.error(`drift: ${name} does not match src/map/`);
      drifted = true;
    }
    continue;
  }

  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, json);
  console.log(`wrote ${name}`);
}

if (drifted) {
  console.error('\nRun `npm run build:style` in apps/web and commit the result.');
  process.exit(1);
}
