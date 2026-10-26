import { useCallback, useEffect, useRef, useState } from 'react';
import type { Map as MapLibreMap } from 'maplibre-gl';
import type { MapMode } from '../../map/mapMode';
import { NARROW_WIDTH, cameraFor, cardFor, isPlainClick, nextStep, onScreen, sameView, stepsFor, tourStart, withCard, type CardId, type TourSeen, type TourStep, type TourView, type UserEvent } from './tourRules.ts';
import { loadTourSeen, saveTourSeen } from './tourStore.ts';

export interface TourOptions {
  map: MapLibreMap | null;
  isDemo: boolean;
  /** Null until the account's history and the map are both ready, so every step has something to point at. */
  hasActivities: boolean | null;
  /** The map opened at `/?tour` (App.tsx). */
  requested: boolean;
  mode: MapMode;
  setMode: (mode: MapMode) => void;
  /** The Edit window is open: its lock holds the panel, and the map's controls are gone. */
  blocked: boolean;
}

interface Running {
  steps: TourStep[];
  index: number;
  /** The mode to put back when the tour ends. */
  restore: MapMode;
}

export interface Tour {
  step: TourStep | null;
  index: number;
  total: number;
  next: () => void;
  back: () => void;
  end: () => void;
  /** The step's anchor never appeared (a phone's hidden control): move on in the last direction. */
  missing: () => void;
  start: () => void;
  offer: boolean;
  takeOffer: () => void;
  declineOffer: () => void;
  tip: boolean;
  closeTip: () => void;
  card: CardId | null;
  closeCard: () => void;
  /** A mode or tab the user picked, which may earn a first-time card. */
  notice: (event: UserEvent) => void;
}

const viewport = () => ({ width: window.innerWidth, height: window.innerHeight });

/** Whether a step can be pointed at now. A step in another mode can't be checked until the map is in it, so it counts as shown; Tour.tsx reports it missing if it isn't. */
function shownNow(step: TourStep, mode: MapMode): boolean {
  if (step.anchor === null || step.mode !== mode) return true;
  const el = document.querySelector(step.anchor);
  return el !== null && onScreen(el.getBoundingClientRect(), viewport());
}

/** The tour, its offer and the first-time cards (docs/SPEC.md FR-4.18): the state around tourRules.ts. */
export function useTour({ map, isDemo, hasActivities, requested, mode, setMode, blocked }: TourOptions): Tour {
  const [seen, setSeen] = useState<TourSeen>(loadTourSeen);
  const [running, setRunning] = useState<Running | null>(null);
  const [offer, setOffer] = useState(false);
  const [tip, setTip] = useState(false);
  const [card, setCard] = useState<CardId | null>(null);
  const dir = useRef<1 | -1>(1);

  useEffect(() => saveTourSeen(seen), [seen]);

  // The latest values for callbacks the header's link and timers hold on to.
  const latest = useRef({ mode, blocked, isDemo, running });
  latest.current = { mode, blocked, isDemo, running };

  const go = useCallback(
    (run: Running, index: number | null) => {
      if (index === null) {
        setMode(run.restore);
        setRunning(null);
        return;
      }
      const step = run.steps[index]!;
      setMode(step.mode);
      if (step.card !== null) setSeen((s) => withCard(s, step.card!));
      setRunning({ ...run, index });
    },
    [setMode],
  );

  const start = useCallback(() => {
    const { mode: current, blocked: isBlocked, isDemo: demo, running: already } = latest.current;
    if (isBlocked || already !== null) return;
    setOffer(false);
    setTip(false);
    setCard(null);
    setSeen((s) => ({ ...s, tour: true }));
    dir.current = 1;
    const run: Running = { steps: stepsFor({ isDemo: demo, narrow: window.innerWidth < NARROW_WIDTH }), index: -1, restore: current };
    go(run, nextStep(run.steps, -1, 1, (s) => shownNow(s, current)));
  }, [go]);

  const move = useCallback(
    (d: 1 | -1) => {
      const run = latest.current.running;
      if (run === null) return;
      dir.current = d;
      go(run, nextStep(run.steps, run.index, d, (s) => shownNow(s, latest.current.mode)));
    },
    [go],
  );
  const next = useCallback(() => move(1), [move]);
  const back = useCallback(() => move(-1), [move]);
  const missing = useCallback(() => move(dir.current), [move]);
  const end = useCallback(() => {
    const run = latest.current.running;
    if (run !== null) go(run, null);
  }, [go]);

  // Decided once, when the history and the map are ready.
  const decided = useRef(false);
  useEffect(() => {
    if (decided.current) return;
    const decision = tourStart({ requested, isDemo, hasActivities, seen });
    if (decision === 'wait') return;
    decided.current = true;
    if (decision === 'start') start();
    if (decision === 'offer') setOffer(true);
  }, [requested, isDemo, hasActivities, seen, start]);

  useTourStartLink(start);
  useTourCamera(map, running?.steps[running.index] ?? null);

  const takeOffer = useCallback(() => start(), [start]);
  const declineOffer = useCallback(() => {
    setOffer(false);
    setSeen((s) => ({ ...s, tour: true }));
    setTip(true);
  }, []);
  const closeTip = useCallback(() => setTip(false), []);
  const closeCard = useCallback(() => setCard(null), []);

  const notice = useCallback(
    (event: UserEvent) => {
      const earned = cardFor(event, seen, running !== null);
      setCard(earned);
      if (earned !== null) setSeen((s) => withCard(s, earned));
    },
    [seen, running],
  );

  return {
    step: running?.steps[running.index] ?? null,
    index: running?.index ?? 0,
    total: running?.steps.length ?? 0,
    next,
    back,
    end,
    missing,
    start,
    offer,
    takeOffer,
    declineOffer,
    tip,
    closeTip,
    card,
    closeCard,
    notice,
  };
}

/**
 * Takes over the header's Take a tour link (`[data-tour-start]`, templates/header.html) on the map
 * page: a plain click starts the tour in place, with no reload. Every other page follows the link
 * to `/?tour`, as does a click that opens a new tab here.
 */
function useTourStartLink(start: () => void) {
  useEffect(() => {
    const onClick = (event: MouseEvent) => {
      const link = (event.target as Element | null)?.closest?.('[data-tour-start]');
      if (!link || !isPlainClick(event)) return;
      event.preventDefault();
      start();
    };
    document.addEventListener('click', onClick);
    return () => document.removeEventListener('click', onClick);
  }, [start]);
}


/** How long the globe takes over each leg of a step's `turn`. */
const TURN_LEG_MS = 5000;

/**
 * Moves the camera to each step's view (tourRules.ts's cameraFor): a flight to a step's own view,
 * then its turn, and back to the view from before the first flight for a step without one and when
 * the tour ends. That view is read at the first flight, not at the start, since the map's own first
 * flight to the account's activities may still be under way then. A real account's steps have no
 * view, so its camera never moves. Reduced motion jumps, and makes the turn a jump to each of its
 * points in turn, since the turn is how the step shows every side of the globe. A flat view sets
 * the projection and the zoom floor (useMapInstance.ts's globe floor) aside for its step only.
 */
function useTourCamera(map: MapLibreMap | null, step: TourStep | null) {
  const start = useRef<TourView | null>(null);
  const shown = useRef<TourView | null>(null);
  useEffect(() => {
    if (!map) return;
    if (step === null) {
      if (start.current && shown.current && !sameView(shown.current, start.current)) moveTo(map, start.current);
      start.current = shown.current = null;
      return;
    }
    if (start.current === null && step.view !== null) {
      const c = map.getCenter();
      start.current = shown.current = { center: [c.lng, c.lat], zoom: map.getZoom() };
    }
    const target = cameraFor(step, start.current);
    if (target === null || (shown.current && sameView(shown.current, target))) return;
    shown.current = target;
    const restoreGlobe = target.flat ? flatten(map) : null;
    moveTo(map, target);
    const legs = [...(target.turn ?? [])];
    if (restoreGlobe) return restoreGlobe;
    if (legs.length === 0) return;
    if (reducedMotion()) {
      const timers = legs.map((leg, i) => window.setTimeout(() => map.jumpTo({ center: [leg[0], leg[1]] }), TURN_LEG_MS * (i + 1)));
      return () => timers.forEach((timer) => window.clearTimeout(timer));
    }
    const turn = () => {
      const leg = legs.shift();
      if (!leg) return;
      map.easeTo({ center: [leg[0], leg[1]], duration: TURN_LEG_MS, easing: (t) => t });
      map.once('moveend', turn);
    };
    map.once('moveend', turn);
    return () => {
      map.off('moveend', turn);
    };
  }, [map, step]);
}

/** Draws the world flat and lifts the globe's zoom floor; returns what puts both back. */
function flatten(map: MapLibreMap): () => void {
  const projection = map.getProjection();
  const floor = map.getMinZoom();
  map.setProjection({ type: 'mercator' });
  map.setMinZoom(0);
  return () => {
    map.setMinZoom(floor);
    map.setProjection(projection);
  };
}

function reducedMotion(): boolean {
  return window.matchMedia('(prefers-reduced-motion: reduce)').matches;
}

function moveTo(map: MapLibreMap, view: TourView) {
  map.stop();
  const camera = { center: [view.center[0], view.center[1]] as [number, number], zoom: view.zoom };
  if (reducedMotion()) map.jumpTo(camera);
  else map.flyTo({ ...camera, duration: 2000, essential: false });
}