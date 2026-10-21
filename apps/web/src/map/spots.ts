import { createElement, type ComponentType } from 'react';
import { flushSync } from 'react-dom';
import { createRoot } from 'react-dom/client';
import type { GeoJSONSource, Map as MapLibreMap, MapGeoJSONFeature } from 'maplibre-gl';
import type { FeatureCollection, Point } from 'geojson';
import { Binoculars, Castle, createLucideIcon, Dog, Landmark, type LucideProps } from 'lucide-react';
import type { components } from '../apiSchema';
import { currentLayers, setLayerToggles, setLayerVars } from './applyLayers';
import { IMAGES_METADATA } from './mapLayers';
import { mapTapsActive } from './mapTaps';
import { SPOT_CATEGORY_WIRE, SPOTS_IN_AREA_LAYER_ID, SPOTS_IN_AREA_SOURCE_ID, SPOTS_LAYER_ID } from './spotsGroup';

/**
 * The Spots layers on the map (IMPLEMENTATION.md §4.25, ADR-0021): the layers document draws them
 * (spotsGroup.ts), and this keeps what the client decides — the categories the Layers menu has on,
 * the account's captures, "Show in this area"'s places — and draws the badge images the document
 * names, in its colors, with the app's own icons.
 */

export { SPOTS_IN_AREA_MIN_ZOOM, SPOTS_MIN_ZOOM } from './spotsGroup';

export type SpotCategory = components['schemas']['Spot']['category'];

/** Every category, in the order the Layers menu lists them. */
export const SPOT_CATEGORIES: readonly SpotCategory[] = SPOT_CATEGORY_WIRE;

/** Lucide has no seesaw, so this one is drawn in its grid and stroke: a plank tilted over an
 *  A-frame, a handle at each end, the ground under it. */
const Seesaw = createLucideIcon('seesaw', [
  ['path', { d: 'M2 15 22 9', key: 'plank' }],
  ['path', { d: 'm8 20 4-8 4 8', key: 'frame' }],
  ['path', { d: 'M5 14v-3', key: 'handle-low' }],
  ['path', { d: 'M19 10V7', key: 'handle-high' }],
  ['path', { d: 'M3 20h18', key: 'ground' }],
]);

const CATEGORY_ICONS: Record<SpotCategory, ComponentType<LucideProps>> = {
  playground: Seesaw,
  dog_park: Dog,
  monument: Landmark,
  viewpoint: Binoculars,
  history: Castle,
};

/** One place as `GET /v1/spots` returns it (api.ts), text fields absent when OSM has none. */
export type SpotInArea = components['schemas']['Spot'];

/** One spot as the popup needs it — a tile feature's properties, typed. */
export interface Spot {
  id: number;
  category: SpotCategory;
  name: string | null;
  address: string | null;
  /** OSM's text about it, each null when it has none — see SpotPopup. */
  description: string | null;
  inscription: string | null;
  memorial: string | null;
  startDate: string | null;
  /** OSM's `wikipedia` tag, "lang:Article title". */
  wikipedia: string | null;
  lon: number;
  lat: number;
}

const BADGE_PX = 30;
const PIXEL_RATIO = 2;

/** A badge as the document gives it (spotsGroup.ts): its category, and its colors. */
interface Badge {
  category: SpotCategory;
  fill: string;
  ring: string;
  ink: string;
}

/** The icon's own SVG children, rendered once from its Lucide component, so the map's icon is
 *  the same drawing the rest of the app uses. */
function iconMarkup(Icon: ComponentType<LucideProps>): string {
  const host = document.createElement('div');
  const root = createRoot(host);
  flushSync(() => root.render(createElement(Icon)));
  const markup = host.querySelector('svg')?.innerHTML ?? '';
  root.unmount();
  return markup;
}

function badgeSVG(icon: string, { fill, ring, ink }: Badge): string {
  // Lucide draws in a 24-unit box; 16 of the badge's 30 units leaves a comfortable margin.
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" width="${BADGE_PX * PIXEL_RATIO}" height="${BADGE_PX * PIXEL_RATIO}" viewBox="0 0 30 30">` +
    `<circle cx="15" cy="15" r="13.5" fill="${fill}" stroke="${ring}" stroke-width="2"/>` +
    `<g transform="translate(7 7) scale(${16 / 24})" fill="none" stroke="${ink}" stroke-width="2.25" stroke-linecap="round" stroke-linejoin="round">${icon}</g>` +
    `</svg>`
  );
}

async function rasterize(svg: string): Promise<ImageData> {
  const img = new Image();
  img.src = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
  await img.decode();
  const size = BADGE_PX * PIXEL_RATIO;
  const canvas = document.createElement('canvas');
  canvas.width = size;
  canvas.height = size;
  const ctx = canvas.getContext('2d');
  if (!ctx) throw new Error('no 2d canvas');
  ctx.drawImage(img, 0, 0, size, size);
  return ctx.getImageData(0, 0, size, size);
}

/**
 * The badge images, drawn once per page from the badges the document names. Module-level because a
 * theme swap (`setStyle`) drops a style's images along with its layers, and they're added back from
 * here — the drawing is asynchronous (an SVG has to decode before it can be drawn), the adding isn't.
 */
let images: Map<string, ImageData> | null = null;
let imagesLoading: Promise<void> | null = null;

function loadImages(badges: Record<string, Badge>): Promise<void> {
  imagesLoading ??= (async () => {
    // Out of the caller's stack first: ensureSpotsLayer runs inside a React effect, where
    // iconMarkup's flushSync can't render — the first icon came out blank.
    await Promise.resolve();
    const drawn = new Map<string, ImageData>();
    const markup = new Map<SpotCategory, string>();
    for (const [name, badge] of Object.entries(badges)) {
      const Icon = CATEGORY_ICONS[badge.category];
      if (!Icon) continue;
      if (!markup.has(badge.category)) markup.set(badge.category, iconMarkup(Icon));
      drawn.set(name, await rasterize(badgeSVG(markup.get(badge.category)!, badge)));
    }
    images = drawn;
  })();
  return imagesLoading;
}

/** Every badge the document's symbol layers name. */
function documentBadges(map: MapLibreMap): Record<string, Badge> {
  const spots = currentLayers(map)?.groups.find((group) => group.id === 'spots');
  return Object.assign({}, ...(spots?.layers ?? []).map((layer) => (layer.metadata as Record<string, unknown> | undefined)?.[IMAGES_METADATA] ?? {}));
}

/** "Show in this area"'s places for each map, kept so a theme swap puts them back. */
const inAreaData = new WeakMap<MapLibreMap, FeatureCollection<Point>>();

/**
 * Registers the badge images the document names on `map`, drawing them on the first call, puts
 * "Show in this area"'s places back, and shows `categories`. Re-run on every `styledata`, since a
 * theme swap drops the images and the GeoJSON with the layers.
 */
export function ensureSpotsLayer(map: MapLibreMap, categories: readonly SpotCategory[]): void {
  setSpotsVisible(map, categories);
  if (!images) {
    const badges = documentBadges(map);
    if (Object.keys(badges).length === 0) return;
    void loadImages(badges).then(() => {
      // The map may have been removed (the page moved on) while the images were drawn.
      if (map.getStyle()) ensureSpotsLayer(map, categories);
    });
    return;
  }
  for (const [name, image] of images) {
    if (!map.hasImage(name)) map.addImage(name, image, { pixelRatio: PIXEL_RATIO });
  }
  const data = inAreaData.get(map);
  if (data) (map.getSource(SPOTS_IN_AREA_SOURCE_ID) as GeoJSONSource | undefined)?.setData(data);
  attachSpotInteractivity(map);
}

/** Shows the chosen categories (the Layers menu, overlays.ts) and hides the rest, every layer
 *  hidden when none is chosen. */
export function setSpotsVisible(map: MapLibreMap, categories: readonly SpotCategory[]): void {
  setLayerVars(map, { spotCategories: [...categories] });
  setLayerToggles(map, { spots: categories.length > 0 });
}

/** Draws the account's captured places (FR-15.6) with the captured badge, the rest plain, and
 *  shows the retired ones among them. */
export function setSpotsCaptured(map: MapLibreMap, captured: readonly number[]): void {
  setLayerVars(map, { captured: [...captured] });
}

/** Draws "Show in this area"'s places (ShowInArea.tsx), replacing the last ones; null clears. */
export function setSpotsInArea(map: MapLibreMap, spots: readonly SpotInArea[] | null): void {
  const data: FeatureCollection<Point> = {
    type: 'FeatureCollection',
    features: (spots ?? []).map(({ lon, lat, ...properties }) => ({
      type: 'Feature',
      geometry: { type: 'Point', coordinates: [lon, lat] },
      properties: { ...properties, lon, lat },
    })),
  };
  inAreaData.set(map, data);
  (map.getSource(SPOTS_IN_AREA_SOURCE_ID) as GeoJSONSource | undefined)?.setData(data);
}

/** The showing spot at a map point, if any — from the tiles or from "Show in this area".
 *  tracks.ts's click handler asks first, so a click on a spot doesn't also select, or unfocus,
 *  a track under it. */
export function spotAt(map: MapLibreMap, point: { x: number; y: number }): Spot | null {
  const layers = [SPOTS_LAYER_ID, SPOTS_IN_AREA_LAYER_ID].filter(
    (id) => map.getLayer(id) && map.getLayoutProperty(id, 'visibility') !== 'none',
  );
  if (layers.length === 0) return null;
  const hit = map.queryRenderedFeatures([point.x, point.y], { layers })[0];
  return hit ? toSpot(hit) : null;
}

/** A tile feature's text property: absent (OSM had none) is null, as is an empty string. */
function text(value: unknown): string | null {
  return typeof value === 'string' && value ? value : null;
}

function toSpot(feature: MapGeoJSONFeature): Spot {
  const p = feature.properties;
  return {
    id: Number(p.id),
    category: p.category as SpotCategory,
    name: text(p.name),
    address: text(p.address),
    description: text(p.description),
    inscription: text(p.inscription),
    memorial: text(p.memorial),
    startDate: text(p.start_date),
    wikipedia: text(p.wikipedia),
    lon: Number(p.lon),
    lat: Number(p.lat),
  };
}

let onSpotClick: ((spot: Spot | null) => void) | null = null;

/** Set once from MapView: a click on a spot opens its popup (SpotPopup), a click anywhere else
 *  on the map closes it (null). */
export function setSpotClickHandler(next: (spot: Spot | null) => void): void {
  onSpotClick = next;
}

// Once per map instance, like tracks.ts's interactiveMaps: a layer-scoped listener keeps
// matching the layer re-added under the same id after a theme swap.
const interactiveMaps = new WeakSet<MapLibreMap>();

function attachSpotInteractivity(map: MapLibreMap): void {
  if (interactiveMaps.has(map)) return;
  interactiveMaps.add(map);
  for (const id of [SPOTS_LAYER_ID, SPOTS_IN_AREA_LAYER_ID]) {
    map.on('mouseenter', id, () => {
      if (mapTapsActive()) map.getCanvas().style.cursor = 'pointer';
    });
    map.on('mouseleave', id, () => {
      map.getCanvas().style.cursor = '';
    });
  }
  // One map-wide handler deciding both, rather than a layer click plus the popup's own
  // closeOnClick: those two fire on the same click, and a click on a second spot while one
  // popup was open opened the new one and closed it again.
  map.on('click', (e) => {
    if (mapTapsActive()) onSpotClick?.(spotAt(map, e.point));
  });
}
