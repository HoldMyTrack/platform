import type { LayerSpecification } from 'maplibre-gl';
import { bandsGroup } from './bandsGroup.ts';
import { bikePathsGroup } from './bikePathsGroup.ts';
import { coverageGroup } from './coverageGroup.ts';
import { spotsGroup } from './spotsGroup.ts';
import { tracksGroup } from './tracksGroup.ts';
import type { MapMode } from './mapMode';
import type { Flavor } from './style';

/**
 * Every layer HoldMyTrack draws over the basemap, as one document per flavor and account
 * (ARCHITECTURE.md §2.1, ADR-0048): the groups in paint order, what each mode shows and how, the
 * zoom tiers and the defaults of the values a client binds at run time. The server serves it as
 * `GET /v1/map/layers`, rendered from this module by build-style.mjs; the web builds it
 * in-process. Clients apply it as it comes (applyLayers.ts, Android's `MapLayers`), holding no
 * look of their own. Pure and DOM-free, like style.ts.
 *
 * Contract (services/server/api, `MapLayers`):
 * - A group's `placement` is `beneath-labels` (under the basemap's first label layer) or `top`;
 *   within a placement the groups' order is paint order, and `lifts` names basemap layers moved
 *   up to the group's place, beneath its own layers.
 * - Source tiles are paths with the tile version filled in: the client adds its base URL, and
 *   its own query where it keeps one (the tracks' range), never `cv`. A `geojson` source the
 *   client fills.
 * - Runtime hooks travel as layer metadata, never as values: TOGGLE_METADATA names the Layers
 *   menu switch that shows a layer, VARS_METADATA the properties (or `filter`) that read one of
 *   the document's `vars` through `["var", name]`, which the client binds with `let`, and
 *   ROLE_METADATA what a layer is for. Selection is by id sets bound this way: measured on the
 *   web, a filter change re-requests no tile and drops no frame, settling a frame or two later
 *   than feature-state, which MapLibre Native Android lacks.
 * - Every view sets the same properties, so a switch never undoes one. A layer is shown when its
 *   view shows it or doesn't list it, its switch is on and the client hasn't hidden its group; it
 *   is added hidden, or as the plain Normal view leaves it, until the client first applies that.
 * - Every array in a filter, layout or paint is an expression, since MapLibre Native reads them
 *   as expressions.
 */

/** Mirrors `tilesPrefix` in services/server/internal/httpapi/server.go. */
export const TILES = '/tiles/v1';

export const TOGGLE_METADATA = 'holdmytrack:toggle';
export const VARS_METADATA = 'holdmytrack:vars';
/** What a layer is for, so a client can draw something of its own to match it (Android's live
 *  recording line takes the `track` layer's color). */
export const ROLE_METADATA = 'holdmytrack:role';
/** The images a symbol layer draws, by name, each a badge the client draws in the colors given. */
export const IMAGES_METADATA = 'holdmytrack:images';

export type Placement = 'beneath-labels' | 'top';

export type GroupSource =
  | { type: 'vector'; tiles: string; minzoom: number; maxzoom: number; attribution?: string }
  | { type: 'geojson' };

/** A Layers menu legend line: the color, and the dash in line widths, or none for solid. */
export interface LegendEntry {
  color: string;
  dash?: number[];
}

export interface LayerGroup {
  id: string;
  placement: Placement;
  lifts?: string[];
  sources: Record<string, GroupSource>;
  layers: LayerSpecification[];
  legend?: Record<string, LegendEntry>;
}

export interface LayerView {
  layout: Record<string, Record<string, unknown>>;
  paint: Record<string, Record<string, unknown>>;
}

export type ZoomTier = 'country' | 'region' | 'city';

/** A tier, drawn below `below`; the last has none. */
export interface LayerTier {
  tier: ZoomTier;
  below?: number;
}

export interface MapLayers {
  /** The build both documents came from (build-style.mjs); empty when built in-process. */
  styleBuild: string;
  flavor: Flavor;
  tileVersion: string;
  tiers: LayerTier[];
  /** Each run-time value a layer can read, at what it is until the client binds its own. */
  vars: Record<string, unknown>;
  /** `satellite` while satellite imagery is drawn, `plain` otherwise. */
  views: Record<'plain' | 'satellite', Record<MapMode, LayerView>>;
  groups: LayerGroup[];
}

/** One family's part of the document: its group and its share of a mode's view over a base
 *  that reads `dark`. */
export interface GroupPart {
  group: LayerGroup;
  view: (mode: MapMode, dark: boolean) => LayerView;
  vars?: Record<string, unknown>;
  tiers?: LayerTier[];
}

/** A source's tile path for `kind` at `tileVersion`. */
export function tilePath(kind: string, tileVersion: string, extension = 'mvt'): string {
  const path = `${TILES}/${kind}/{z}/{x}/{y}.${extension}`;
  return tileVersion ? `${path}?cv=${encodeURIComponent(tileVersion)}` : path;
}

/** `spec` as `view` leaves it, so a layer drawn before its first view already looks right. */
export function withView(spec: LayerSpecification, view: LayerView): LayerSpecification {
  return {
    ...spec,
    layout: { ...('layout' in spec ? spec.layout : {}), ...view.layout[spec.id] },
    paint: { ...('paint' in spec ? spec.paint : {}), ...view.paint[spec.id] },
  } as LayerSpecification;
}

const MODES: readonly MapMode[] = ['normal', 'fog', 'heatmap'];

function mergeViews(parts: readonly GroupPart[], mode: MapMode, dark: boolean): LayerView {
  const view: LayerView = { layout: {}, paint: {} };
  for (const part of parts) {
    const own = part.view(mode, dark);
    Object.assign(view.layout, own.layout);
    Object.assign(view.paint, own.paint);
  }
  return view;
}

export interface BuildLayersOptions {
  flavor: Flavor;
  /** Whether the flavor draws light on dark (style.ts's isDarkFlavor). */
  dark: boolean;
  /** The basemap's label layers (style.ts's basemapLabelIds). */
  labelIds: readonly string[];
  tileVersion: string;
  styleBuild?: string;
}

/** The layers document for `flavor` at `tileVersion`. Satellite imagery reads dark under any
 *  flavor, so its views take the dark ones. */
export function buildLayers({ flavor, dark, labelIds, tileVersion, styleBuild = '' }: BuildLayersOptions): MapLayers {
  const parts = [coverageGroup(dark, tileVersion, labelIds), bikePathsGroup(flavor, tileVersion), tracksGroup(tileVersion), bandsGroup(), spotsGroup(tileVersion)];
  const views = (base: boolean) => Object.fromEntries(MODES.map((mode) => [mode, mergeViews(parts, mode, base)])) as Record<MapMode, LayerView>;
  return {
    styleBuild,
    flavor,
    tileVersion,
    tiers: parts.flatMap((part) => part.tiers ?? []),
    vars: Object.assign({}, ...parts.map((part) => part.vars ?? {})),
    views: { plain: views(dark), satellite: views(true) },
    groups: parts.map((part) => part.group),
  };
}

/** The view to apply for `mode`, over imagery or not. */
export function viewFor(doc: MapLayers, mode: MapMode, satellite: boolean): LayerView {
  return doc.views[satellite ? 'satellite' : 'plain'][mode];
}

/** The tier in view at `zoom`: the first whose `below` is past it. */
export function zoomTier(tiers: readonly LayerTier[], zoom: number): ZoomTier {
  return tiers.find((t) => t.below === undefined || zoom < t.below)?.tier ?? 'city';
}

/** Every layer id of `placement`, the basemap layers groups lift included, in paint order. */
export function placementOrder(groups: readonly LayerGroup[], placement: Placement): string[] {
  return groups.filter((group) => group.placement === placement).flatMap((group) => [...(group.lifts ?? []), ...group.layers.map((layer) => layer.id)]);
}

/**
 * Where layer `id` goes in, or a lifted basemap layer moves to, among the map's `current` layers
 * (bottom to top): under the next one after it in `order` that's already in place, else under
 * `fallback`. A basemap layer to lift is in place only once it's above the lowest of `own`.
 */
export function insertionPoint(current: readonly string[], order: readonly string[], id: string, own: ReadonlySet<string>, fallback: string | undefined): string | undefined {
  const lowest = current.findIndex((other) => own.has(other));
  return (
    order.slice(order.indexOf(id) + 1).find((next) => {
      const at = current.indexOf(next);
      return at >= 0 && (own.has(next) || (lowest >= 0 && at > lowest));
    }) ?? fallback
  );
}

/** Whether basemap layer `id` still sits below the lowest of `own`, so has to be lifted. */
export function needsLift(current: readonly string[], id: string, own: ReadonlySet<string>): boolean {
  const at = current.indexOf(id);
  const lowest = current.findIndex((other) => own.has(other));
  return at >= 0 && !(lowest >= 0 && at > lowest);
}

/** The group `id`, or undefined for a document without it. */
export function groupOf(doc: MapLayers, id: string): LayerGroup | undefined {
  return doc.groups.find((group) => group.id === id);
}

/** `value` with each of `names` bound to the client's `vars`, or the document's default, as a
 *  `let` expression around it. */
export function bindVars(value: unknown, names: readonly string[], vars: Readonly<Record<string, unknown>>, defaults: Readonly<Record<string, unknown>>): unknown {
  if (names.length === 0) return value;
  const bindings = names.flatMap((name) => {
    const bound = name in vars ? vars[name] : defaults[name];
    return [name, Array.isArray(bound) ? ['literal', bound] : bound];
  });
  return ['let', ...bindings, value];
}

/** The layer's VARS_METADATA: which of its properties, or its filter, read which vars. */
export function layerVars(layer: LayerSpecification): Record<string, string[]> {
  const metadata = layer.metadata as Record<string, unknown> | undefined;
  return (metadata?.[VARS_METADATA] as Record<string, string[]> | undefined) ?? {};
}

/** The Layers menu switch that shows `layer`, if any. */
export function layerToggle(layer: LayerSpecification): string | undefined {
  const metadata = layer.metadata as Record<string, unknown> | undefined;
  const toggle = metadata?.[TOGGLE_METADATA];
  return typeof toggle === 'string' ? toggle : undefined;
}

/** `layer` with every var it reads bound, as the client adds it. */
export function boundLayer(layer: LayerSpecification, vars: Readonly<Record<string, unknown>>, defaults: Readonly<Record<string, unknown>>): LayerSpecification {
  const reads = Object.entries(layerVars(layer));
  if (reads.length === 0) return layer;
  const layout: Record<string, unknown> = { ...('layout' in layer ? layer.layout : {}) };
  const paint: Record<string, unknown> = { ...('paint' in layer ? layer.paint : {}) };
  let filter = 'filter' in layer ? layer.filter : undefined;
  for (const [property, names] of reads) {
    if (property === 'filter') filter = bindVars(filter, names, vars, defaults) as never;
    else if (property in layout) layout[property] = bindVars(layout[property], names, vars, defaults);
    else if (property in paint) paint[property] = bindVars(paint[property], names, vars, defaults);
  }
  return { ...layer, layout, paint, ...(filter !== undefined && { filter }) } as LayerSpecification;
}
