import { buildLayers, type MapLayers } from './mapLayers';
import { basemapLabelIds, isDarkFlavor, type Flavor } from './style';

const built = new Map<Flavor, MapLayers>();

/**
 * The layers document for the web's own maps, built in-process as the style is
 * (ARCHITECTURE.md §2.1), and kept per flavor until the tile version moves: building reads the
 * whole basemap style for its label ids, and the map applies it on every `styledata`.
 */
export function webLayers(flavor: Flavor, tileVersion: string): MapLayers {
  const cached = built.get(flavor);
  if (cached?.tileVersion === tileVersion) return cached;
  const doc = buildLayers({ flavor, dark: isDarkFlavor(flavor), labelIds: basemapLabelIds(flavor), tileVersion });
  built.set(flavor, doc);
  return doc;
}
