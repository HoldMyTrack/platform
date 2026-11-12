import { Popup, type Map as MapLibreMap, type MapGeoJSONFeature } from 'maplibre-gl';
import { hasKey, t, tn } from '../i18n';
import { PLACE_FILL_LAYERS } from './coverageGroup';
import { placeLabel } from './fogPlaceLabel';
import { mapTapsActive } from './mapTaps';

/**
 * In Fog, the outline under the pointer on every level but Exact is highlighted (its `hover`
 * state, which the layers document's border and fill read) and named in a tooltip: what it is,
 * where, and whether it is explored. Web only: the apps will open the same on a tap.
 */

type Hovered = { source: string; sourceLayer: string; id: string | number };

const attached = new WeakSet<MapLibreMap>();

/** Wires the hover once per map instance, like tracks.ts: the layers it queries are re-added
 *  under the same ids after a style swap, and are hidden outside Fog, so it needs no mode. */
export function attachFogPlaces(map: MapLibreMap): void {
  if (attached.has(map)) return;
  attached.add(map);

  let hovered: Hovered | null = null;
  const popup = new Popup({ closeButton: false, closeOnClick: false, focusAfterOpen: false, offset: 14, className: 'fog-place-tip', maxWidth: '260px' });
  const name = document.createElement('div');
  name.className = 'fog-place-tip__name';
  const detail = document.createElement('div');
  detail.className = 'fog-place-tip__detail';
  const state = document.createElement('div');
  state.className = 'fog-place-tip__detail';
  const content = document.createElement('div');
  content.append(name, detail, state);
  popup.setDOMContent(content);

  const setHover = (next: Hovered | null) => {
    if (hovered && next && hovered.source === next.source && hovered.id === next.id) return;
    if (hovered) map.setFeatureState(hovered, { hover: false });
    hovered = next;
    if (hovered) map.setFeatureState(hovered, { hover: true });
  };
  const clear = () => {
    setHover(null);
    popup.remove();
  };

  map.on('mousemove', (e) => {
    const layers = PLACE_FILL_LAYERS.filter((id) => map.getLayer(id));
    const feature: MapGeoJSONFeature | undefined = mapTapsActive() && layers.length ? map.queryRenderedFeatures(e.point, { layers })[0] : undefined;
    const label = feature ? placeLabel(feature.properties ?? {}, hasKey) : null;
    if (!feature || !label || feature.id === undefined || !feature.sourceLayer) {
      clear();
      return;
    }
    setHover({ source: feature.source, sourceLayer: feature.sourceLayer, id: feature.id });
    name.textContent = label.name;
    detail.textContent = [t(label.kindKey), label.within].filter(Boolean).join(' · ');
    // Explored, and of each level below, how many of its places in it are: 34 of 88 counties.
    const counts = label.counts.map((c) => tn(c.key as Parameters<typeof tn>[0], c.total, { explored: c.explored }));
    state.textContent = label.visitedKey === 'map.fog.place.visited' ? [t(label.visitedKey), ...counts].join(' · ') : t(label.visitedKey);
    popup.setLngLat(e.lngLat);
    if (!popup.isOpen()) popup.addTo(map);
  });
  map.on('mouseout', clear);
  map.on('movestart', () => popup.remove());
}
