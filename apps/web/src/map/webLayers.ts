import { lang } from '../i18n';
import { buildLayers, type MapLayers } from './mapLayers';
import { isDarkFlavor, type Flavor } from './style';

const built = new Map<Flavor, MapLayers>();

/** What the account's country calls its regions and counties: the server's (the Account's
 *  `fog_words`), which its own layers document carries for the apps. */
let words = { region: '', county: '' };

/** Sets the account's words, once it's known; the documents built before it are rebuilt. */
export function setFogWords(next: { region: string; county: string }): void {
  words = next;
  built.clear();
}

/**
 * The layers document for the web's own maps, built in-process as the style is
 * (ARCHITECTURE.md §2.1), and kept per flavor until the tile version moves: building reads the
 * whole basemap style for its label ids, and the map applies it on every `styledata`.
 */
export function webLayers(flavor: Flavor, tileVersion: string): MapLayers {
  const cached = built.get(flavor);
  if (cached?.tileVersion === tileVersion) return cached;
  const doc = buildLayers({ flavor, dark: isDarkFlavor(flavor), tileVersion, lang, words });
  built.set(flavor, doc);
  return doc;
}
