/**
 * The tour's decisions (docs/SPEC.md FR-4.18), as values in and values out: which steps run, when
 * the tour starts by itself or is offered, which first-time card a user's own action earns, and
 * where the popover sits. useTour.ts holds the state around them, Tour.tsx draws it.
 */
import type { MapMode } from '../../map/mapMode';
import type { PanelTab } from '../ActivitiesPanel';

/** A first-time card: the feature's own explanation, shown once per browser. */
export type CardId = 'fog' | 'heatmap' | 'stories';

export type StepId = 'welcome' | 'activities' | 'range' | 'stories' | 'layers' | 'export' | 'fog' | 'fog_regions' | 'fog_countries' | 'heatmap' | 'add' | 'done';

/** Where a step puts the camera: `center` and `zoom`, then a slow turn of the globe through each point of `turn`, if any. */
export interface TourView {
  center: readonly [longitude: number, latitude: number];
  zoom: number;
  turn?: readonly (readonly [longitude: number, latitude: number])[];
}

export interface TourStep {
  id: StepId;
  /** A CSS selector for the element the step points at; null centers the popover. */
  anchor: string | null;
  /** The mode the map is put in for the step. The panel's steps need Normal, which is the only mode that shows it. */
  mode: MapMode;
  /** The card this step's text stands in for: seeing the step counts as seeing the card. */
  card: CardId | null;
  /** The i18n key prefix: `<text>.title` and `<text>.body`. */
  text: string;
  /** The camera for the step; null keeps the view the tour started on. */
  view: TourView | null;
}

const MODES = '[data-testid="map-mode-toggle"]';

/**
 * The demo's views, over its fixed history (services/server/internal/httpapi/demo_data): Cleveland,
 * where most of it is; the US, where Fog clears states (zoom 3–6, SPEC.md FR-4.2); and the globe,
 * where it clears countries (zoom 0–2), turning from the US over Europe (Estonia, Italy) to
 * Vietnam because a globe shows one side of the Earth at a time. Each leg is under 180°, so the
 * turn goes east.
 */
export const DEMO_VIEWS = {
  city: { center: [-81.72, 41.42], zoom: 9 },
  // East of the middle: a phone's narrow view still holds Ohio, New York and Florida, a desktop's Arizona too.
  regions: { center: [-82, 36], zoom: 3.6 },
  countries: { center: [-80, 38], zoom: 1.5, turn: [[15, 45], [106, 25]] },
  heatmapCity: { center: [-81.72, 41.42], zoom: 10 },
} as const satisfies Record<string, TourView>;

/**
 * The tour's steps in order. The Normal-mode steps come first, so the panel is never torn down and
 * rebuilt in the middle. A demo's Fog is three steps, city, states and countries, and its Fog and
 * Heatmap fly to the demo's history; a real account's map stays where it is.
 */
export function stepsFor({ isDemo }: { isDemo: boolean }): TourStep[] {
  const step = (id: StepId, anchor: string | null, more: Partial<Omit<TourStep, 'id' | 'anchor'>> = {}): TourStep => ({
    id,
    anchor,
    mode: 'normal',
    card: null,
    text: `tour.${id}`,
    view: null,
    ...more,
  });
  const fog = isDemo
    ? [
        step('fog', MODES, { mode: 'fog', card: 'fog', text: 'tour.fog_city', view: DEMO_VIEWS.city }),
        step('fog_regions', MODES, { mode: 'fog', view: DEMO_VIEWS.regions }),
        step('fog_countries', MODES, { mode: 'fog', view: DEMO_VIEWS.countries }),
      ]
    : [step('fog', MODES, { mode: 'fog', card: 'fog' })];
  return [
    step('welcome', null),
    step('activities', '[data-testid="activities-panel"]'),
    step('range', '[data-testid="date-range-slider"]'),
    step('stories', '[data-testid="activities-panel-tab-stories"]', { card: 'stories' }),
    step('layers', '[data-testid="map-overlays"]'),
    step('export', '[data-testid="export-button"]'),
    ...fog,
    step('heatmap', MODES, { mode: 'heatmap', card: 'heatmap', view: isDemo ? DEMO_VIEWS.heatmapCity : null }),
    // The header's Upload menu; the demo's is a disabled button that says what an account adds.
    step('add', '.page-header .upload-menu', { text: isDemo ? 'tour.add_demo' : 'tour.add' }),
    step('done', '[data-tour-start]'),
  ];
}

/** The camera a step wants: its own view, or the one before the tour's first move; null while nothing has moved. Equal views mean no move. */
export function cameraFor(step: TourStep, start: TourView | null): TourView | null {
  return step.view ?? start;
}

export function sameView(a: TourView, b: TourView): boolean {
  return a.center[0] === b.center[0] && a.center[1] === b.center[1] && a.zoom === b.zoom;
}

export interface TourSeen {
  /** The tour was started, or its offer answered: it never starts or is offered by itself again. */
  tour: boolean;
  cards: CardId[];
}

export const NOTHING_SEEN: TourSeen = { tour: false, cards: [] };

export type TourStart = 'start' | 'offer' | 'none' | 'wait';

/**
 * What the map does about the tour when it opens. `requested` is the header's Take a tour or
 * `/?tour`. `hasActivities` is null until the account's history is known. A demo visitor gets the
 * tour unasked, since the demo's data is there to show; a real account is only offered it, and not
 * before it has something on the map.
 */
export function tourStart({ requested, isDemo, hasActivities, seen }: { requested: boolean; isDemo: boolean; hasActivities: boolean | null; seen: TourSeen }): TourStart {
  if (hasActivities === null) return 'wait';
  if (requested) return 'start';
  if (seen.tour) return 'none';
  if (isDemo) return 'start';
  return hasActivities ? 'offer' : 'none';
}

/** Something the user did that may earn a first-time card. */
export type UserEvent = { kind: 'mode'; mode: MapMode } | { kind: 'tab'; tab: PanelTab };

/** The card a user's own action shows, once: never while the tour runs, which explains the same thing. */
export function cardFor(event: UserEvent, seen: TourSeen, touring: boolean): CardId | null {
  if (touring) return null;
  let card: CardId | null = null;
  if (event.kind === 'mode' && event.mode !== 'normal') card = event.mode;
  if (event.kind === 'tab' && event.tab === 'stories') card = 'stories';
  return card !== null && !seen.cards.includes(card) ? card : null;
}

/** `seen` with `card` added. */
export function withCard(seen: TourSeen, card: CardId): TourSeen {
  return seen.cards.includes(card) ? seen : { ...seen, cards: [...seen.cards, card] };
}

/**
 * The step after `from` in direction `dir` whose anchor `shown` says is on screen (a phone's
 * collapsed panel or a hidden control drops its step), or null past either end. A step with no
 * anchor is always shown.
 */
export function nextStep(steps: readonly TourStep[], from: number, dir: 1 | -1, shown: (step: TourStep) => boolean): number | null {
  for (let i = from + dir; i >= 0 && i < steps.length; i += dir) {
    const step = steps[i]!;
    if (step.anchor === null || shown(step)) return i;
  }
  return null;
}

export interface Rect {
  left: number;
  top: number;
  width: number;
  height: number;
}

export type Placement = { kind: 'center' } | { kind: 'sheet'; edge: 'top' | 'bottom' } | { kind: 'float'; left: number; top: number; side: 'below' | 'above' | 'right' | 'left'; arrow: number };

/** Below this width the popover is a bottom sheet, as the panel is (index.css's phone layer). */
export const NARROW_WIDTH = 768;
const GAP = 14;
const MARGIN = 12;

/**
 * Where a popover of `size` goes beside `anchor` in a `viewport`: below it if it fits, else above,
 * else right or left; clamped inside the viewport, with `arrow` the anchor's center along the
 * popover's edge. No anchor centers it. A narrow screen makes it a sheet across the bottom, or
 * across the top when the anchor is in the lower half (a phone's panel strip), so it never covers
 * what it points at.
 */
export function placePopover(anchor: Rect | null, size: { width: number; height: number }, viewport: { width: number; height: number }): Placement {
  if (viewport.width < NARROW_WIDTH) return { kind: 'sheet', edge: anchor !== null && anchor.top + anchor.height / 2 > viewport.height / 2 ? 'top' : 'bottom' };
  if (anchor === null) return { kind: 'center' };
  const clamp = (v: number, min: number, max: number) => Math.max(min, Math.min(v, max));
  const cx = anchor.left + anchor.width / 2;
  const cy = anchor.top + anchor.height / 2;
  const horizontal = (top: number, side: 'below' | 'above'): Placement => {
    const left = clamp(cx - size.width / 2, MARGIN, viewport.width - size.width - MARGIN);
    return { kind: 'float', left, top, side, arrow: cx - left };
  };
  const vertical = (left: number, side: 'right' | 'left'): Placement => {
    const top = clamp(cy - size.height / 2, MARGIN, viewport.height - size.height - MARGIN);
    return { kind: 'float', left, top, side, arrow: cy - top };
  };
  const below = anchor.top + anchor.height + GAP;
  if (below + size.height <= viewport.height - MARGIN) return horizontal(below, 'below');
  const above = anchor.top - GAP - size.height;
  if (above >= MARGIN) return horizontal(above, 'above');
  const right = anchor.left + anchor.width + GAP;
  if (right + size.width <= viewport.width - MARGIN) return vertical(right, 'right');
  const left = anchor.left - GAP - size.width;
  if (left >= MARGIN) return vertical(left, 'left');
  return { kind: 'center' };
}

/** Whether `rect` is something to point at: laid out, and at least partly in the viewport. */
export function onScreen(rect: Rect, viewport: { width: number; height: number }): boolean {
  return rect.width > 0 && rect.height > 0 && rect.left < viewport.width && rect.top < viewport.height && rect.left + rect.width > 0 && rect.top + rect.height > 0;
}

/** A click the header's Take a tour link should take over: the primary button, no modifier, so a new tab or window still follows the link. */
export function isPlainClick(event: { button: number; metaKey: boolean; ctrlKey: boolean; shiftKey: boolean; altKey: boolean }): boolean {
  return event.button === 0 && !event.metaKey && !event.ctrlKey && !event.shiftKey && !event.altKey;
}