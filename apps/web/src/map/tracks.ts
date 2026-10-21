import type { Map as MapLibreMap } from 'maplibre-gl';
import type { ActivityQuery } from '../api';
import { setLayerVars, updateLayers } from './applyLayers';
import { mapTapsActive } from './mapTaps';
import { PHOTO_MARKER_CLASS } from './photos';
import { spotAt } from './spots';
import { TRACKS_LAYER_ID } from './tracksGroup';

/**
 * The live tracks MVT layer on the map (IMPLEMENTATION.md §4.3): the layers document draws it
 * (tracksGroup.ts), and this keeps what the client decides — the tiles' query, which ids are
 * hidden, focused and hovered, and the clicks and hovers on it. Unlike the basemap the tiles are
 * never precomputed: the backend runs a live PostGIS query per tile.
 */

// Half-width, in screen pixels, of the box a click's hit-test is queried against — see the
// click handler below for why this can't just be the bare click pixel.
const CLICK_TOLERANCE_PX = 4;
// The same for a tap: a fingertip covers ~40px and lands wherever its center falls, so the 8px
// box above missed a track under the finger most of the time — and a miss clears the focus.
const TAP_TOLERANCE_PX = 14;

/** `from`/`to` and a Story (FR-14.4) — `types` stays a client-side-only filter (activityFacets.ts,
 *  setHiddenTracks below), matching DISTANCE, which has no server-side equivalent at all;
 *  keeping both narrowed the same way is simpler than half server-side, half client-side. */
type TrackDateRange = Pick<ActivityQuery, 'from' | 'to' | 'story'>;

/**
 * Bumped by every refreshTrackLayer, and sent as `v` (the handler ignores it) so each refresh
 * is a new tile URL — see refreshTrackLayer for why the same URL isn't enough. Module-level so a
 * source re-created by a theme swap starts at the current one. Sent alongside the tile version
 * (`cv`, in the document's tile path), which is what lets the browser keep a tracks tile: this
 * one only tells refreshes apart within the page, so a refresh after a change the page hasn't
 * read a new tile version for yet (a type edit) still asks again. Prefixed with when the page
 * loaded: the server marks a tile with the caller's own `cv` cacheable for good, so a bare
 * counter, which every page starts again from 1, would have one tab's refresh hit the tile
 * another tab cached under the same `cv` and `v` before the change.
 */
let tracksVersion = 0;
const pageLoaded = Date.now().toString(36);

/**
 * The query the client appends to the tracks tiles: `from`/`to`, or a Story. An omitted filter
 * means "no restriction" to the server, so a bare tile request asks for every track ever
 * uploaded; the Activities list and the map disagreed about what was in view until this was sent.
 */
export function trackQuery(range: TrackDateRange): string {
  const params = new URLSearchParams();
  if (range.from) params.set('from', range.from);
  if (range.to) params.set('to', range.to);
  if (range.story) params.set('story', range.story);
  if (tracksVersion > 0) params.set('v', `${pageLoaded}.${tracksVersion}`);
  return params.toString();
}

// Map instances that already have hover/click handlers attached. A layer-id-scoped delegated
// listener keeps matching a layer re-added under the same id after a theme swap, so attaching on
// every styledata would stack duplicate handlers, firing a click N times after N theme toggles.
const interactiveMaps = new WeakSet<MapLibreMap>();

export interface TrackInteractivityHandlers {
  /** A track was clicked — the caller decides what "selected" means (see MapView). */
  onSelect: (activityId: string) => void;
  /** The pointer entered or left a track — `null` on leave. Reported up rather than applied
   *  directly (as this used to) so ActivitiesPanel's own row hover can drive the exact same
   *  feature-state through one place (setHoveredTrack) instead of the two fighting over
   *  which one a mouseleave should clear. */
  onHover: (activityId: string | null) => void;
  /** A click landed on the map somewhere with no track underneath it — reported live as the
   *  missing counterpart to onSelect: a focused activity had no way to lose that focus by
   *  clicking away from it on the map itself (only by focusing a different one, or via the
   *  Activities panel). MapView clears its own row-click focus on this; it does not touch
   *  the checkbox group, matching that the two are independent everywhere else. */
  onClickAway: () => void;
}

let handlers: TrackInteractivityHandlers | null = null;

/** Set once from MapView; attachTrackInteractivity reads it indirectly so it isn't a
 *  parameter that would need re-passing on every `styledata`. */
export function setTrackInteractivityHandlers(next: TrackInteractivityHandlers): void {
  handlers = next;
}

/**
 * Wires hover (reported up via onHover — see setHoveredTrack for where it's drawn) and click
 * (calls back into MapView, which owns what "selected" persists as) on the tracks layer. Attached once per map instance (interactiveMaps above).
 */
export function attachTrackInteractivity(map: MapLibreMap): void {
  if (interactiveMaps.has(map)) return;
  interactiveMaps.add(map);

  let hoveredId: string | null = null;

  map.on('mousemove', TRACKS_LAYER_ID, (e) => {
    if (!mapTapsActive()) return;
    map.getCanvas().style.cursor = 'pointer';
    // The activity's id as the tile carries it (the tracks query's `id` column).
    const id = e.features?.[0]?.properties?.id as string | undefined;
    if (id === undefined || id === hoveredId) return;
    hoveredId = id;
    handlers?.onHover(id);
  });

  map.on('mouseleave', TRACKS_LAYER_ID, () => {
    map.getCanvas().style.cursor = '';
    if (hoveredId !== null) {
      hoveredId = null;
      handlers?.onHover(null);
    }
  });

  // One plain, map-wide click handler rather than a layer-scoped one — onSelect and
  // onClickAway are two outcomes of the exact same hit-test ("did this click land on a
  // track, or not"), so they share one query instead of running it twice and risking the
  // two disagreeing. Queries TRACKS_LAYER_ID specifically rather than the band overlay:
  // every visible band already sits directly on top of that same activity's own
  // tracks-layer feature, so checking the tracks layer alone is sufficient to tell "on a
  // track" from "not."
  //
  // Queries a small box around the click, not the bare pixel: a track is 2.5px wide, which
  // leaves almost no room for error — a click landing a couple of pixels off the rendered
  // line (easy to do aiming at something this thin) used to just do nothing (harmless), but
  // once a miss started clearing the current focus (onClickAway), the same near-miss became
  // destructive instead. Found live: clicking within 3px of a second activity's track, while
  // a first one was already focused, cleared the first activity's focus and never applied a
  // new one — the exact-pixel query saw neither track under the cursor. CLICK_TOLERANCE_PX
  // is larger than half the hover width (tracksGroup.ts) so a hover-widened line is still
  // comfortably inside its own tolerance box, not just barely.
  map.on('click', (e) => {
    // queryRenderedFeatures throws for a layer id the current style doesn't have, which is
    // real during the brief window between a styledata-triggered setStyle and the layers
    // document going back on.
    if (!map.getLayer(TRACKS_LAYER_ID) || !mapTapsActive()) return;
    // A spot's icon sits on top of the tracks; a click on one opens its popup (spots.ts) and
    // means nothing to the track underneath.
    if (spotAt(map, e.point)) return;
    // Nor does a click on a photo's marker (photos.ts), which opens the photo.
    if ((e.originalEvent.target as Element | null)?.closest?.(`.${PHOTO_MARKER_CLASS}`)) return;
    const { x, y } = e.point;
    const tolerance = isTouch(e.originalEvent) ? TAP_TOLERANCE_PX : CLICK_TOLERANCE_PX;
    const box: [[number, number], [number, number]] = [
      [x - tolerance, y - tolerance],
      [x + tolerance, y + tolerance],
    ];
    const hits = map.queryRenderedFeatures(box, { layers: [TRACKS_LAYER_ID] });
    const id = hits[0]?.properties?.id as string | undefined;
    if (id) handlers?.onSelect(id);
    else handlers?.onClickAway();
  });
}

/** Whether a map click came from a finger. The browser's click after a tap is a PointerEvent
 *  saying so where supported; elsewhere, a coarse primary pointer is the best available guess. */
function isTouch(event: MouseEvent): boolean {
  if ('pointerType' in event && typeof event.pointerType === 'string' && event.pointerType) {
    return event.pointerType === 'touch';
  }
  return window.matchMedia('(pointer: coarse)').matches;
}

/**
 * The one hovered track, drawn widest: fed by both directions, the map's own mousemove and
 * mouseleave above (via onHover) and ActivitiesPanel's row hover (via MapView's hoveredActivityId),
 * so a row hover and a map hover share one piece of state.
 */
export function setHoveredTrack(map: MapLibreMap, activityId: string | null): void {
  setLayerVars(map, { hovered: activityId !== null ? [activityId] : [] });
}

/** The focused tracks, drawn bold over their halo. MapView passes at most one id: the focused
 *  activity; checked rows aren't bolded. */
export function setSelectedTracks(map: MapLibreMap, activityIds: readonly string[]): void {
  setLayerVars(map, { focused: [...activityIds] });
}

/**
 * Forces MapLibre to refetch every tracks tile — a finished upload's track should now show up, or
 * `range` changed and the loaded tiles were built from the old `from`/`to`.
 *
 * Every refresh bumps `tracksVersion`, making the URL new: beyond the source's maxzoom the worker
 * slices each overzoomed tile out of its z14 parent and caches the slice keyed on the tile ids and
 * the request URL (maplibre-gl 6.9.0's `_getOverzoomTile`), so with the URL unchanged an edited
 * track kept its old shape close in until the next zoom level (found live).
 */
export function refreshTrackLayer(map: MapLibreMap, range: TrackDateRange): void {
  tracksVersion += 1;
  updateLayers(map, { queries: { tracks: trackQuery(range) } });
}

/**
 * Per-activity show/hide (the list's eye icon), Type and Distance, and Pending, client-side only:
 * the tracks endpoint already returns everything in range, and hiding a track is a question of
 * which fetched features get painted, which is what a layer filter is for.
 */
export function setHiddenTracks(map: MapLibreMap, hiddenIds: string[]): void {
  setLayerVars(map, { hidden: hiddenIds });
}
