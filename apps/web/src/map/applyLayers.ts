import type { GeoJSONSourceSpecification, LayerSpecification, Map as MapLibreMap, VectorTileSource } from 'maplibre-gl';
import { API_BASE_URL } from '../api';
import type { MapMode } from './mapMode';
import { boundLayer, bindVars, insertionPoint, layerToggle, layerVars, needsLift, placementOrder, viewFor, type GroupSource, type LayerGroup, type MapLayers } from './mapLayers';
import { SATELLITE_LAYER_ID } from './style';

/**
 * The layers document (mapLayers.ts) on a live map: this adds what the document describes,
 * applies the mode's view, the Layers menu's switches and the run-time vars, and decides nothing
 * about how anything looks. Android's `MapLayers` does the same. Every call is idempotent and
 * diffs before it sets, since `styledata` fires on every theme `setStyle`, which discards custom
 * layers, and each `setLayoutProperty`, `setPaintProperty` or `setFilter` re-renders
 * unconditionally and fires another (docs/DEVELOPMENT.md, the setFilter/setLayoutProperty gotcha).
 */

/** What the client decides, the rest being the document's. */
export interface LayerState {
  mode: MapMode;
  /** Satellite imagery is on; its views apply only while the style has the imagery. */
  satellite: boolean;
  /** By TOGGLE_METADATA name: the Layers menu's switches. A layer with a toggle not set is hidden. */
  toggles: Readonly<Record<string, boolean>>;
  /** By var name, the value bound in place of the document's default. */
  vars: Readonly<Record<string, unknown>>;
  /** Groups the client steps aside, drawn hidden (a track being edited hides the tracks). */
  hiddenGroups: ReadonlySet<string>;
  /** By source id, the client's own query appended to its tiles (the tracks' range). */
  queries: Readonly<Record<string, string>>;
  /** Groups never added to this map (the export's has no Spots). */
  excludedGroups?: ReadonlySet<string>;
}

export const INITIAL_LAYER_STATE: LayerState = {
  mode: 'normal',
  satellite: false,
  toggles: {},
  vars: {},
  hiddenGroups: new Set(),
  queries: {},
};

type LayoutProperty = Parameters<MapLibreMap['getLayoutProperty']>[1];
type PaintProperty = Parameters<MapLibreMap['getPaintProperty']>[1];

const applied = new WeakMap<MapLibreMap, { doc: MapLayers; state: LayerState }>();

/** The document last applied to `map`, or null before the first. */
export function currentLayers(map: MapLibreMap): MapLayers | null {
  return applied.get(map)?.doc ?? null;
}

/** The state last applied to `map`. */
export function currentLayerState(map: MapLibreMap): LayerState {
  return applied.get(map)?.state ?? INITIAL_LAYER_STATE;
}

function groupsOf(doc: MapLayers, state: LayerState): LayerGroup[] {
  return doc.groups.filter((group) => !state.excludedGroups?.has(group.id));
}

function tileURL(source: Extract<GroupSource, { type: 'vector' }>, query: string | undefined): string {
  const url = `${API_BASE_URL}${source.tiles}`;
  if (!query) return url;
  return `${url}${url.includes('?') ? '&' : '?'}${query}`;
}

/** The first label layer that isn't the document's: where `beneath-labels` groups go. */
function labelPoint(map: MapLibreMap, ownIds: ReadonlySet<string>): string | undefined {
  return map.getLayersOrder().find((id) => !ownIds.has(id) && map.getLayer(id)?.type === 'symbol');
}

function beforeIdFor(map: MapLibreMap, order: readonly string[], id: string, ownIds: ReadonlySet<string>, fallback: string | undefined): string | undefined {
  return insertionPoint(map.getLayersOrder(), order, id, ownIds, fallback);
}

function addSources(map: MapLibreMap, group: LayerGroup, state: LayerState): void {
  for (const [id, source] of Object.entries(group.sources)) {
    const existing = map.getSource(id);
    if (source.type === 'geojson') {
      if (!existing) map.addSource(id, { type: 'geojson', data: { type: 'FeatureCollection', features: [] } } satisfies GeoJSONSourceSpecification);
      continue;
    }
    const url = tileURL(source, state.queries[id]);
    if (existing) {
      // A new tile version or query: the same source, re-pointed, which MapLibre treats as new tiles.
      const vector = existing as VectorTileSource;
      if (vector.tiles?.[0] !== url) vector.setTiles([url]);
      continue;
    }
    map.addSource(id, {
      type: 'vector',
      tiles: [url],
      minzoom: source.minzoom,
      maxzoom: source.maxzoom,
      ...(source.attribution && { attribution: source.attribution }),
    });
  }
}

/**
 * Applies `doc` with `state` to `map`: adds the sources and layers not on it yet, at their place
 * in the stack, lifts the basemap layers a group names, re-points a source whose tiles changed
 * (a new tile version), and sets every view, switch and var.
 */
export function applyLayers(map: MapLibreMap, doc: MapLayers, state: LayerState): void {
  applied.set(map, { doc, state });
  const groups = groupsOf(doc, state);
  const ownIds = new Set(groups.flatMap((group) => group.layers.map((layer) => layer.id)));
  const beneath = placementOrder(groups, 'beneath-labels');
  const top = placementOrder(groups, 'top');
  const labels = labelPoint(map, ownIds);
  for (const group of groups) {
    addSources(map, group, state);
    const order = group.placement === 'top' ? top : beneath;
    const fallback = group.placement === 'top' ? undefined : labels;
    for (const id of group.lifts ?? []) liftLayer(map, beneath, ownIds, id, labels);
    for (const layer of group.layers) {
      if (map.getLayer(layer.id)) continue;
      // A layer this renderer refuses is skipped, so one family degrades instead of the map.
      try {
        map.addLayer(boundLayer(layer, state.vars, doc.vars), beforeIdFor(map, order, layer.id, ownIds, fallback));
      } catch (err) {
        console.error(`layers document: ${layer.id} skipped`, err);
      }
    }
  }
  applyState(map, doc, state, groups);
}

/** `patch` merged into the state last applied to `map`, and applied; a no-op before the first
 *  applyLayers. */
export function updateLayers(map: MapLibreMap, patch: Partial<LayerState>): void {
  const current = applied.get(map);
  if (!current) return;
  applyLayers(map, current.doc, { ...current.state, ...patch });
}

/** `vars` merged into the vars last applied to `map`. */
export function setLayerVars(map: MapLibreMap, vars: Readonly<Record<string, unknown>>): void {
  updateLayers(map, { vars: { ...currentLayerState(map).vars, ...vars } });
}

/** `toggles` merged into the switches last applied to `map`. */
export function setLayerToggles(map: MapLibreMap, toggles: Readonly<Record<string, boolean>>): void {
  updateLayers(map, { toggles: { ...currentLayerState(map).toggles, ...toggles } });
}

/** Moves the basemap layer `id` up to its place among the groups, if it's still below the lowest
 *  of them: a style swap puts it back among the roads, and the next call lifts it again. */
function liftLayer(map: MapLibreMap, beneath: readonly string[], ownIds: ReadonlySet<string>, id: string, labels: string | undefined): void {
  if (needsLift(map.getLayersOrder(), id, ownIds)) map.moveLayer(id, beforeIdFor(map, beneath, id, ownIds, labels));
}

function setLayout(map: MapLibreMap, id: string, property: string, value: unknown): void {
  if (JSON.stringify(map.getLayoutProperty(id, property as LayoutProperty) ?? null) !== JSON.stringify(value ?? null)) {
    map.setLayoutProperty(id, property as LayoutProperty, value as never);
  }
}

function setPaint(map: MapLibreMap, id: string, property: string, value: unknown): void {
  if (JSON.stringify(map.getPaintProperty(id, property as PaintProperty) ?? null) !== JSON.stringify(value ?? null)) {
    map.setPaintProperty(id, property as PaintProperty, value as never);
  }
}

function applyState(map: MapLibreMap, doc: MapLayers, state: LayerState, groups: readonly LayerGroup[]): void {
  const view = viewFor(doc, state.mode, state.satellite && map.getLayer(SATELLITE_LAYER_ID) !== undefined);
  const own = new Map<string, { layer: LayerSpecification; group: LayerGroup }>();
  for (const group of groups) for (const layer of group.layers) own.set(layer.id, { layer, group });

  // The basemap's own layers a view sets: its labels, which Fog mutes.
  for (const [id, props] of Object.entries(view.layout)) {
    if (own.has(id) || !map.getLayer(id)) continue;
    for (const [property, value] of Object.entries(props)) setLayout(map, id, property, value);
  }
  for (const [id, props] of Object.entries(view.paint)) {
    if (own.has(id) || !map.getLayer(id)) continue;
    for (const [property, value] of Object.entries(props)) setPaint(map, id, property, value);
  }

  for (const [id, { layer, group }] of own) {
    if (!map.getLayer(id)) continue;
    const layout = view.layout[id] ?? {};
    for (const [property, value] of Object.entries(layout)) if (property !== 'visibility') setLayout(map, id, property, value);
    for (const [property, value] of Object.entries(view.paint[id] ?? {})) setPaint(map, id, property, value);

    // What a layer is added with holds until this first runs; from then the view, the switch
    // and the hidden groups decide.
    const base = (layout.visibility ?? 'visible') === 'visible';
    const toggle = layerToggle(layer);
    const shown = base && (toggle === undefined || state.toggles[toggle] === true) && !state.hiddenGroups.has(group.id);
    setLayout(map, id, 'visibility', shown ? 'visible' : 'none');

    for (const [property, names] of Object.entries(layerVars(layer))) {
      if (property === 'filter') {
        const next = bindVars('filter' in layer ? layer.filter : undefined, names, state.vars, doc.vars);
        if (JSON.stringify(map.getFilter(id) ?? null) !== JSON.stringify(next)) map.setFilter(id, next as never);
      } else if ('layout' in layer && layer.layout && property in layer.layout) {
        setLayout(map, id, property, bindVars((layer.layout as Record<string, unknown>)[property], names, state.vars, doc.vars));
      } else if ('paint' in layer && layer.paint && property in layer.paint) {
        setPaint(map, id, property, bindVars((layer.paint as Record<string, unknown>)[property], names, state.vars, doc.vars));
      }
    }
  }
}
