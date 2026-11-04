/** Writes the chevron font (chevronFont.mjs) beside the basemap's fonts. Usage: node scripts/build-chevron-font.mjs */
import { mkdir, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { CHEVRON_FONT, CHEVRON_RANGE, chevronFontBytes } from './chevronFont.mjs';

const dir = join(dirname(fileURLToPath(import.meta.url)), '..', 'public', 'basemap', 'fonts', CHEVRON_FONT);
await mkdir(dir, { recursive: true });
await writeFile(join(dir, `${CHEVRON_RANGE}.pbf`), chevronFontBytes());
