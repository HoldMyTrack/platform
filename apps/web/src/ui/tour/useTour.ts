import { useCallback, useEffect, useRef, useState } from 'react';
import type { MapMode } from '../../map/mapMode';
import { cardFor, isPlainClick, nextStep, onScreen, stepsFor, tourStart, withCard, type CardId, type TourSeen, type TourStep, type UserEvent } from './tourRules.ts';
import { loadTourSeen, saveTourSeen } from './tourStore.ts';

export interface TourOptions {
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
export function useTour({ isDemo, hasActivities, requested, mode, setMode, blocked }: TourOptions): Tour {
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
    const run: Running = { steps: stepsFor({ isDemo: demo }), index: -1, restore: current };
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
