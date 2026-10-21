import { useEffect, useRef, useState } from 'react';
import type { KeyboardEvent, MouseEvent as ReactMouseEvent, PointerEvent as ReactPointerEvent } from 'react';
import { ChevronLeft, ChevronRight, ChevronsLeft, ChevronsRight } from 'lucide-react';
import type { HistogramBucket } from '../api';
import { formatDayLabel } from './format';
import type { DateRange } from './dateMath';
import { sliderBoundaries, sliderLayout, sliderMoveKnob, sliderPanLand, sliderTicks, type SliderWindow } from './sliderRules';
import { lang, t, tn } from '../i18n';

export interface DateRangeSliderProps {
  /** The window: consecutive days-with-activity, ascending — useActivityDays' `visibleDays`. */
  days: HistogramBucket[];
  /** Moves the window by whole activity-days — negative is toward the past. */
  onPan: (deltaDays: number) => void;
  canPanEarlier: boolean;
  canPanLater: boolean;
  /** The range-shift buttons: `range` moved its own length in activity-days, the window
   *  following it — or null when it can't move (useActivityDays' `shift`). */
  onShift: (range: DateRange, dir: -1 | 1) => DateRange | null;
  canShift: (range: DateRange, dir: -1 | 1) => boolean;
  value: DateRange;
  onChange: (next: DateRange) => void;
  /** How many activity-days the row has room for (sliderLayout), each time that changes. */
  onWindowDays: (days: number) => void;
}

type Knob = 'start' | 'end';

/** A month's short name in the page's language, under its tall tick. */
function monthName(month: number): string {
  return new Date(Date.UTC(2026, month - 1, 1)).toLocaleDateString(lang, { month: 'short', timeZone: 'UTC' });
}

/** How near a knob, in px, a press grabs it rather than starting a swipe or a tap: half a 48px
 *  target either side. */
const KNOB_GRAB_PX = 24;

/** How far a press away from the knobs moves before it's a swipe rather than a tap. */
const SWIPE_SLOP_PX = 8;

/** How often a knob held past an edge steps the window again. */
const EDGE_REPEAT_MS = 500;

/** Under this many px a slot, the knobs narrow so neighbours stay apart. */
const NARROW_SLOT_PX = 18;

/** The room ‹ › take in the row beside « track »: two 28px buttons and their 6px gaps. */
const SHIFT_PAIR_PX = 2 * (28 + 6);

/** How far one Earlier/Later tap moves the window, in activity-days. */
const STEP_DAYS = 5;

/** Press-and-hold on Earlier/Later: the first step is immediate, then it repeats. */
const REPEAT_DELAY_MS = 400;
const REPEAT_INTERVAL_MS = 180;

/**
 * The date-range control (`SPEC.md` FR-6), on the Activities tab alone: a two-knob slider in one
 * row, « ‹ track › », with the selected dates under it. The same control as Android's
 * (`DayScrubberView`); the rules both share are sliderRules.ts.
 *
 * **Activity-days, not calendar days**: one slot per day the user recorded something, none for
 * the days between, so a quiet month costs no track. The window, its paging and the history
 * fetches behind them are useActivityDays'; how many days it holds, and whether « » show, follow
 * the row's width and the pointer (sliderLayout).
 *
 * **Knobs sit on slot boundaries, not on slots.** The start knob marks where the first selected
 * day begins and the end knob where the last one ends, so a one-day selection has its knobs one
 * slot apart and the two can never be dragged closer than that.
 *
 * **Gestures.** A press near a knob carries it; held past the edge it's moving toward, it pages
 * the window that way every EDGE_REPEAT_MS, pulled along. A press elsewhere is a swipe once it
 * moves, scrolling the window a day per slot, or a tap that brings the nearer knob to it. Each
 * knob is also a focusable `role="slider"`.
 *
 * **Paging.** « » move the window STEP_DAYS per tap (repeating while held). A knob sitting on the
 * edge the window moves toward is pulled along with it, which is how a selection grows past the
 * window. Only the far knob can scroll out of view; its date stays in the label under the track.
 * The pull lands once the moved window has rendered (the days before it may still be loading), so
 * a gesture's commit waits for that too.
 *
 * Drags and held buttons render from a local draft and commit only on release, so the activity
 * list isn't refetched for every day passed.
 *
 * **Range shift.** ‹ › move the whole selection by its own length in activity-days, packed against
 * the old range (rangeShift.ts), and the window follows. A tap commits; a hold repeats and commits
 * on release.
 *
 * **Day marks.** A tick on every slot boundary, tall where a month starts, with the month's name
 * under it and the first month in view at the left edge (sliderTicks). Ticks inside the selection
 * take the accent.
 */
export function DateRangeSlider({
  days,
  onPan,
  canPanEarlier,
  canPanLater,
  onShift,
  canShift,
  value,
  onChange,
  onWindowDays,
}: DateRangeSliderProps) {
  const rowRef = useRef<HTMLDivElement>(null);
  const trackRef = useRef<HTMLDivElement>(null);
  /** The press on the track, until release: a knob carried, or one not yet a swipe or a tap. */
  const gestureRef = useRef<
    | { pointerId: number; kind: 'knob'; knob: Knob; edge: -1 | 0 | 1; edgeTimer: number }
    | { pointerId: number; kind: 'undecided' | 'swipe'; downX: number; anchorX: number }
    | null
  >(null);
  const [buttons, setButtons] = useState(true);
  const repeatRef = useRef<{ timer: number } | null>(null);
  /** A pan asked for and not yet rendered, the knobs it pulls along, and whether the gesture
   *  has ended and should commit once it lands. */
  const panRef = useRef<{ start: boolean; end: boolean; commit: boolean } | null>(null);

  const [draft, setDraft] = useState<DateRange | null>(null);
  const current = draft ?? value;

  const n = days.length;
  const firstDay = days[0]?.date;
  const lastDay = days[n - 1]?.date;

  // ---- Dates ↔ slot boundaries (sliderRules.ts) -----------------------------------------

  const slider: SliderWindow = { days: days.map((d) => d.date), canPanEarlier, canPanLater };
  const startOf = (from: string) => sliderBoundaries(slider, { from, to: from }).start;
  const endOf = (to: string) => sliderBoundaries(slider, { from: to, to }).end;

  const start = startOf(current.from);
  const end = endOf(current.to);
  const clamp = (b: number) => Math.min(Math.max(b, 0), n);
  const percent = (b: number) => (n === 0 ? 0 : (clamp(b) / n) * 100);

  const moveKnob = (knob: Knob, b: number, sel: DateRange): DateRange => sliderMoveKnob(slider, sel, knob, b);

  // Latest values for the press-and-hold timer and the pull effect, which outlive the render
  // that started them.
  const live = useRef({ current, canPanEarlier, canPanLater, onPan, onShift, startOf, endOf, n });
  live.current = { current, canPanEarlier, canPanLater, onPan, onShift, startOf, endOf, n };

  const commit = (next: DateRange | null) => {
    setDraft(null);
    if (!next || (next.from === value.from && next.to === value.to)) return;
    onChange(next);
  };

  // ---- Earlier / Later ------------------------------------------------------------------

  // A pan has rendered: pull the knobs it was carrying onto the new edges, then commit if
  // the gesture that asked for it is already over.
  useEffect(() => {
    const pan = panRef.current;
    if (!pan || !firstDay || !lastDay) return;
    const next = sliderPanLand(slider.days, live.current.current, pan.start, pan.end);
    live.current.current = next;
    panRef.current = null;
    if (pan.commit) {
      commit(next);
      flushRef.current();
    } else setDraft(next);
  }, [firstDay, lastDay]);

  /** Moves the window STEP_DAYS; a knob on the edge being moved toward is pulled along once
   *  the moved window renders. False once the window is already at that end of the history. */
  const step = (dir: -1 | 1): boolean => {
    const now = live.current;
    if (!(dir < 0 ? now.canPanEarlier : now.canPanLater)) return false;
    panRef.current = {
      // `||` with a pan still in flight: its window hasn't rendered, so this one's edges are stale.
      start: panRef.current?.start || (dir < 0 && now.startOf(now.current.from) === 0),
      end: panRef.current?.end || (dir > 0 && now.endOf(now.current.to) === now.n),
      commit: false,
    };
    now.onPan(dir * STEP_DAYS);
    return true;
  };

  /** Moves the selection its own length; false when it can't move that way (yet). */
  const shiftStep = (dir: -1 | 1): boolean => {
    const now = live.current;
    const next = now.onShift(now.current, dir);
    if (!next) return false;
    now.current = next;
    setDraft(next);
    return true;
  };

  /** Ends a gesture: commits now, or once a pan still in flight has landed. */
  const finish = () => {
    if (panRef.current) panRef.current.commit = true;
    else commit(live.current.current);
    flushWindowDays();
  };

  // ---- Size -----------------------------------------------------------------------------
  // The row's width decides how many activity-days the window holds (sliderLayout). A new size
  // mid-gesture would move the boundaries under the pointer, so it waits for the release.

  const sizeRef = useRef<{ reported: number | null; waiting: number | null }>({ reported: null, waiting: null });
  const onWindowDaysRef = useRef(onWindowDays);
  onWindowDaysRef.current = onWindowDays;
  const busy = () => gestureRef.current !== null || repeatRef.current !== null || panRef.current !== null;
  const flushWindowDays = () => {
    const size = sizeRef.current;
    if (size.waiting === null || busy()) return;
    const next = size.waiting;
    size.waiting = null;
    if (next === size.reported) return;
    size.reported = next;
    onWindowDaysRef.current(next);
  };
  const flushRef = useRef(flushWindowDays);
  flushRef.current = flushWindowDays;

  useEffect(() => {
    const row = rowRef.current;
    if (!row) return;
    const fine = window.matchMedia('(pointer: fine)');
    const measure = () => {
      const layout = sliderLayout(row.clientWidth - SHIFT_PAIR_PX, fine.matches);
      setButtons(layout.buttons);
      sizeRef.current.waiting = layout.days;
      flushRef.current();
    };
    const observer = new ResizeObserver(measure);
    observer.observe(row);
    fine.addEventListener('change', measure);
    return () => {
      observer.disconnect();
      fine.removeEventListener('change', measure);
    };
  }, []);

  const stopRepeat = () => {
    const repeat = repeatRef.current;
    if (!repeat) return;
    window.clearTimeout(repeat.timer);
    repeatRef.current = null;
    finish();
  };

  /** Press-and-hold on any of the four buttons: `action` once now, then repeating. */
  const startRepeat = (action: () => boolean, event: ReactPointerEvent<HTMLButtonElement>) => {
    event.preventDefault();
    event.currentTarget.setPointerCapture(event.pointerId);
    action();
    const tick = () => {
      // Reaching the end disables the button, and a disabled button gets no pointerup — so
      // the hold ends (and commits) here instead.
      if (!action()) return stopRepeat();
      if (repeatRef.current) repeatRef.current.timer = window.setTimeout(tick, REPEAT_INTERVAL_MS);
    };
    repeatRef.current = { timer: window.setTimeout(tick, REPEAT_DELAY_MS) };
  };

  useEffect(() => () => window.clearTimeout(repeatRef.current?.timer), []);

  const pageButton = (dir: -1 | 1) => (
    <button
      type="button"
      className="date-range-slider__page date-range-slider__page--window"
      data-testid={dir < 0 ? 'date-range-slider-earlier' : 'date-range-slider-later'}
      aria-label={dir < 0 ? tn('slider.days_earlier', STEP_DAYS) : tn('slider.days_later', STEP_DAYS)}
      title={dir < 0 ? t('slider.earlier') : t('slider.later')}
      disabled={dir < 0 ? !canPanEarlier : !canPanLater}
      onPointerDown={(event) => startRepeat(() => step(dir), event)}
      onPointerUp={stopRepeat}
      onPointerCancel={stopRepeat}
      // Pointer presses are handled above; this is the keyboard's Enter/Space (detail 0).
      onClick={(event: ReactMouseEvent) => {
        if (event.detail !== 0) return;
        step(dir);
        finish();
      }}
    >
      {dir < 0 ? <ChevronsLeft size={14} /> : <ChevronsRight size={14} />}
    </button>
  );

  const shiftButton = (dir: -1 | 1) => (
    <button
      type="button"
      className="date-range-slider__page date-range-slider__page--shift"
      data-testid={dir < 0 ? 'date-range-slider-shift-earlier' : 'date-range-slider-shift-later'}
      aria-label={dir < 0 ? t('slider.shift_earlier') : t('slider.shift_later')}
      title={dir < 0 ? t('slider.shift_earlier') : t('slider.shift_later')}
      disabled={!canShift(current, dir)}
      onPointerDown={(event) => startRepeat(() => shiftStep(dir), event)}
      onPointerUp={stopRepeat}
      onPointerCancel={stopRepeat}
      onClick={(event: ReactMouseEvent) => {
        if (event.detail !== 0) return;
        shiftStep(dir);
        finish();
      }}
    >
      {dir < 0 ? <ChevronLeft size={16} /> : <ChevronRight size={16} />}
    </button>
  );

  // ---- The track ------------------------------------------------------------------------

  /** The slot boundary nearest a clientX, not clamped to the window, and the track's geometry. */
  const geometry = (clientX: number) => {
    const rect = trackRef.current!.getBoundingClientRect();
    const slot = n === 0 ? 0 : rect.width / n;
    return { x: clientX - rect.left, slot, boundary: slot === 0 ? 0 : Math.round((clientX - rect.left) / slot) };
  };

  // A press is one of three gestures, as on Android: near a drawn knob it carries the knob; away
  // from them, a move past the slop is a swipe that scrolls the window a day per slot (the days
  // follow the pointer) and a release without moving is a tap that brings the nearer knob there.

  const onPointerDown = (event: ReactPointerEvent<HTMLDivElement>) => {
    if (!trackRef.current || n === 0) return;
    event.preventDefault();
    event.currentTarget.setPointerCapture(event.pointerId);
    const { x, slot, boundary } = geometry(event.clientX);
    const near = (['start', 'end'] as const)
      .map((which) => ({ which, at: which === 'start' ? start : end }))
      .filter(({ at }) => at >= 0 && at <= n && Math.abs(at * slot - x) <= KNOB_GRAB_PX)
      .sort((a, b) => Math.abs(a.at * slot - x) - Math.abs(b.at * slot - x))[0];
    if (near) {
      gestureRef.current = { pointerId: event.pointerId, kind: 'knob', knob: near.which, edge: 0, edgeTimer: 0 };
      setDraft(moveKnob(near.which, clamp(boundary), current));
    } else {
      gestureRef.current = { pointerId: event.pointerId, kind: 'undecided', downX: x, anchorX: x };
    }
  };

  const stopEdge = () => {
    const gesture = gestureRef.current;
    if (gesture?.kind !== 'knob' || gesture.edge === 0) return;
    window.clearInterval(gesture.edgeTimer);
    gesture.edge = 0;
  };

  const onPointerMove = (event: ReactPointerEvent<HTMLDivElement>) => {
    const gesture = gestureRef.current;
    if (!gesture || gesture.pointerId !== event.pointerId) return;
    const { x, slot, boundary } = geometry(event.clientX);
    if (gesture.kind === 'knob') {
      // Held past the edge it's moving toward, a knob pages the window that way.
      const past: -1 | 0 | 1 =
        gesture.knob === 'start' && boundary < 0 && canPanEarlier ? -1 : gesture.knob === 'end' && boundary > n && canPanLater ? 1 : 0;
      if (past !== gesture.edge) {
        stopEdge();
        if (past !== 0) {
          gesture.edge = past;
          step(past);
          gesture.edgeTimer = window.setInterval(() => {
            if (!step(past)) stopEdge();
          }, EDGE_REPEAT_MS);
        }
      }
      if (past === 0 && draft) setDraft(moveKnob(gesture.knob, clamp(boundary), draft));
      return;
    }
    if (gesture.kind === 'undecided') {
      if (Math.abs(x - gesture.downX) <= SWIPE_SLOP_PX) return;
      gestureRef.current = { ...gesture, kind: 'swipe' };
    }
    const swipe = gestureRef.current;
    if (swipe?.kind !== 'swipe' || slot === 0) return;
    const moved = Math.trunc((x - swipe.anchorX) / slot);
    if (moved === 0) return;
    swipe.anchorX += moved * slot;
    // Toward the right is toward the past: the days follow the pointer, as a list does.
    if ((moved > 0 && canPanEarlier) || (moved < 0 && canPanLater)) onPan(-moved);
  };

  const onPointerUp = (event: ReactPointerEvent<HTMLDivElement>) => {
    const gesture = gestureRef.current;
    if (!gesture || gesture.pointerId !== event.pointerId) return;
    stopEdge();
    gestureRef.current = null;
    if (gesture.kind === 'knob') {
      live.current.current = draft ?? current;
      finish();
    } else if (gesture.kind === 'undecided' && event.type === 'pointerup') {
      const b = clamp(geometry(event.clientX).boundary);
      // An off-screen knob counts as sitting on the edge it went past.
      const knob: Knob = Math.abs(b - clamp(start)) <= Math.abs(b - clamp(end)) ? 'start' : 'end';
      commit(moveKnob(knob, b, current));
      flushWindowDays();
    } else flushWindowDays();
  };

  useEffect(() => () => {
    const gesture = gestureRef.current;
    if (gesture?.kind === 'knob') window.clearInterval(gesture.edgeTimer);
  }, []);

  const onKnobKeyDown = (knob: Knob, event: KeyboardEvent) => {
    const at = knob === 'start' ? start : end;
    const delta = { ArrowLeft: -1, ArrowDown: -1, ArrowRight: 1, ArrowUp: 1, PageDown: -STEP_DAYS, PageUp: STEP_DAYS }[event.key];
    const target = event.key === 'Home' ? 0 : event.key === 'End' ? n : delta !== undefined ? at + delta : null;
    if (target === null) return;
    event.preventDefault();
    setDraft(moveKnob(knob, target, current));
  };

  const knob = (which: Knob) => {
    const at = which === 'start' ? start : end;
    return (
      n > 0 &&
      at >= 0 &&
      at <= n && (
        <span
          className="date-range-slider__knob"
          role="slider"
          tabIndex={0}
          aria-label={which === 'start' ? t('slider.start') : t('slider.end')}
          aria-valuemin={0}
          aria-valuemax={n}
          aria-valuenow={at}
          aria-valuetext={formatDayLabel(which === 'start' ? current.from : current.to)}
          data-testid={`date-range-slider-${which}`}
          style={{ left: `${percent(at)}%` }}
          onKeyDown={(event) => onKnobKeyDown(which, event)}
          onKeyUp={() => commit(draft)}
          onBlur={() => commit(draft)}
        />
      )
    );
  };

  const ticks = sliderTicks(slider.days);
  const narrow = n > 0 && (trackRef.current?.clientWidth ?? Infinity) / n < NARROW_SLOT_PX;

  return (
    <div className="date-range-slider" data-testid="date-range-slider">
      <div ref={rowRef} className="date-range-slider__row">
        {buttons && pageButton(-1)}
        {shiftButton(-1)}
        <div
          ref={trackRef}
          className={`date-range-slider__track${narrow ? ' date-range-slider__track--narrow' : ''}`}
          data-testid="date-range-slider-track"
          onPointerDown={onPointerDown}
          onPointerMove={onPointerMove}
          onPointerUp={onPointerUp}
          onPointerCancel={onPointerUp}
        >
          <div className="activity-filters__track" />
          {ticks.map((tick) => (
            <span
              key={tick.boundary}
              className={`date-range-slider__tick date-range-slider__tick--${tick.kind}${
                clamp(end) > clamp(start) && tick.boundary >= clamp(start) && tick.boundary <= clamp(end) ? ' date-range-slider__tick--selected' : ''
              }`}
              style={{ left: `${percent(tick.boundary)}%` }}
            />
          ))}
          {ticks.map(
            (tick) =>
              tick.month !== null && (
                <span
                  key={`month-${tick.boundary}`}
                  className={`date-range-slider__month${tick.boundary === 0 ? ' date-range-slider__month--first' : ''}`}
                  style={{ left: `${percent(tick.boundary)}%` }}
                >
                  {monthName(tick.month)}
                </span>
              ),
          )}
          {n > 0 && clamp(end) > clamp(start) && (
            <div
              className="activity-filters__fill"
              style={{ left: `${percent(start)}%`, right: `${100 - percent(end)}%` }}
            />
          )}
          {knob('start')}
          {knob('end')}
        </div>
        {shiftButton(1)}
        {buttons && pageButton(1)}
      </div>
      <div className="date-range-slider__labels" data-testid="date-range-slider-labels">
        <span>{formatDayLabel(current.from)}</span>
        <span>{formatDayLabel(current.to)}</span>
      </div>
    </div>
  );
}
