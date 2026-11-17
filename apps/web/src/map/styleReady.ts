import type { Map as MapLibreMap } from 'maplibre-gl';

/**
 * Whether `map`'s style is loaded, so its sources, layers and `getStyle()` can be used. Between a
 * theme's `setStyle(…, { diff: false })` and the next frame they can't: `addSource` throws and
 * `getStyle()` is undefined. Not `isStyleLoaded()`, which also waits for tiles and so dips to
 * false whenever a source loads (docs/DEVELOPMENT.md). Reads MapLibre's own flag, which has no
 * public accessor.
 */
export function styleReady(map: MapLibreMap): boolean {
  return (map.style as { _loaded?: boolean } | undefined)?._loaded === true;
}
