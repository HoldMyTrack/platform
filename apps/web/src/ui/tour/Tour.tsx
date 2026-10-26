import { useEffect, useLayoutEffect, useMemo, useRef, useState, type CSSProperties, type KeyboardEvent } from 'react';
import { t } from '../../i18n';
import type { MessageKey } from '../../i18n/en';
import { onScreen, placePopover, unionOf, type CardId, type Placement, type Rect } from './tourRules.ts';
import type { Tour } from './useTour';
import './tour.css';

/** The frames a step's anchor gets to appear after a mode change before the step is skipped. */
const MISSING_FRAMES = 20;
/** Room around the anchor inside the spotlight's ring, and the ring's corners (tour.css's --fm-radius-lg). */
const PAD = 6;
const RADIUS = 12;

const CARD_ANCHORS: Record<CardId, string> = {
  fog: '[data-testid="map-mode-toggle"]',
  heatmap: '[data-testid="map-mode-toggle"]',
  stories: '[data-testid="activities-panel-tab-stories"]',
};

/** The tour, its offer, the tip after the offer is declined, and the first-time cards (docs/SPEC.md FR-4.18). A card closes on the next press outside it. */
export function TourLayer({ tour }: { tour: Tour }) {
  return (
    <>
      {tour.step && <TourStepView tour={tour} />}
      {tour.offer && <TourOffer onTake={tour.takeOffer} onLater={tour.declineOffer} />}
      {tour.tip && <TourTip onClose={tour.closeTip} />}
      {tour.card && !tour.step && <FeatureCard card={tour.card} onClose={tour.closeCard} onTour={tour.start} />}
    </>
  );
}

/** The on-screen rects of every element `selector` matches: a button and its open menu are two. */
function anchorRects(selector: string): Rect[] {
  const viewport = { width: window.innerWidth, height: window.innerHeight };
  return [...document.querySelectorAll(selector)]
    .map((el) => el.getBoundingClientRect())
    .filter((r) => onScreen(r, viewport))
    .map((r) => ({ left: r.left, top: r.top, width: r.width, height: r.height }));
}

/**
 * What `selector` matches, each rect lit on its own and their union for placing beside, followed
 * every frame (the panel resizes, the map's controls wrap, a menu opens, a mode change mounts and
 * unmounts the panel). `onMissing` is called once if nothing has appeared within MISSING_FRAMES.
 */
function useAnchor(selector: string | null, onMissing?: () => void): { rects: Rect[]; rect: Rect | null } {
  const [rects, setRects] = useState<Rect[]>([]);
  const missing = useRef(onMissing);
  missing.current = onMissing;
  useEffect(() => {
    setRects([]);
    if (selector === null) return;
    let frame = 0;
    let absent = 0;
    let last = '[]';
    const tick = () => {
      const next = anchorRects(selector);
      if (next.length === 0 && ++absent === MISSING_FRAMES) {
        missing.current?.();
        return;
      }
      if (next.length > 0) absent = 0;
      const key = JSON.stringify(next);
      if (key !== last) {
        last = key;
        setRects(next);
      }
      frame = requestAnimationFrame(tick);
    };
    tick();
    return () => cancelAnimationFrame(frame);
  }, [selector]);
  return { rects, rect: useMemo(() => unionOf(rects), [rects]) };
}

/** A popover's placement beside `rect`, from its own measured size. Hidden until measured. */
function usePlacement(rect: Rect | null) {
  const ref = useRef<HTMLDivElement>(null);
  const [placement, setPlacement] = useState<Placement | null>(null);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const place = () => setPlacement(placePopover(rect, { width: el.offsetWidth, height: el.offsetHeight }, { width: window.innerWidth, height: window.innerHeight }));
    place();
    window.addEventListener('resize', place);
    return () => window.removeEventListener('resize', place);
  }, [rect]);
  return { ref, placement };
}

function popoverStyle(placement: Placement | null): CSSProperties {
  if (placement === null) return { visibility: 'hidden' };
  if (placement.kind === 'float') return { left: placement.left, top: placement.top };
  return {};
}

function popoverClass(base: string, placement: Placement | null): string {
  if (placement === null || placement.kind === 'float') return `${base} ${base}--float`;
  if (placement.kind === 'sheet') return `${base} ${base}--sheet ${base}--sheet-${placement.edge}`;
  return `${base} ${base}--${placement.kind}`;
}

function Arrow({ placement }: { placement: Placement | null }) {
  if (placement?.kind !== 'float') return null;
  const along = placement.side === 'below' || placement.side === 'above' ? { left: placement.arrow } : { top: placement.arrow };
  return <span className={`tour-arrow tour-arrow--${placement.side}`} style={along} aria-hidden="true" />;
}

/** Keeps Tab inside `container`. */
function trapTab(event: KeyboardEvent<HTMLElement>) {
  if (event.key !== 'Tab') return;
  const items = [...event.currentTarget.querySelectorAll<HTMLElement>('button')];
  const first = items[0];
  const last = items[items.length - 1];
  if (!first || !last) return;
  if (event.shiftKey && document.activeElement === first) {
    event.preventDefault();
    last.focus();
  } else if (!event.shiftKey && document.activeElement === last) {
    event.preventDefault();
    first.focus();
  }
}

function TourStepView({ tour }: { tour: Tour }) {
  const step = tour.step!;
  const { rects, rect } = useAnchor(step.anchor, tour.missing);
  const { ref, placement } = usePlacement(rect);
  const primary = useRef<HTMLButtonElement>(null);
  const last = tour.index === tour.total - 1;

  useEffect(() => primary.current?.focus(), [step.id]);
  useHeaderMenuOpen('.page-header details.upload-menu', tour.open.upload === true);
  useEffect(() => {
    const onKey = (event: globalThis.KeyboardEvent) => {
      if (event.key === 'Escape') tour.end();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [tour.end]);

  return (
    <div className={placement?.kind === 'sheet' ? 'tour tour--narrow' : 'tour'} data-testid="tour" data-step={step.id}>
      {/* Takes every click, so nothing under the tour changes while it runs. */}
      <div className="tour__blocker" />
      {/* The dim screen with a hole for each lit rect, so a menu's neighbours stay dim. */}
      <svg className="tour__dim" aria-hidden="true">
        <defs>
          <mask id="tour-holes">
            <rect width="100%" height="100%" fill="white" />
            {rects.map((r, i) => (
              <rect key={i} x={r.left - PAD} y={r.top - PAD} width={r.width + PAD * 2} height={r.height + PAD * 2} rx={RADIUS} fill="black" />
            ))}
          </mask>
        </defs>
        <rect width="100%" height="100%" mask="url(#tour-holes)" />
      </svg>
      {rects.map((r, i) => (
        <div key={i} className="tour__ring" style={{ left: r.left - PAD, top: r.top - PAD, width: r.width + PAD * 2, height: r.height + PAD * 2 }} />
      ))}
      <div ref={ref} className={popoverClass('tour-popover', placement)} style={popoverStyle(placement)} role="dialog" aria-modal="true" aria-labelledby="tour-title" onKeyDown={trapTab}>
        <Arrow placement={placement} />
        <div className="tour-popover__head">
          <h2 id="tour-title" className="tour-popover__title">{t(`${step.text}.title` as MessageKey)}</h2>
          <span className="tour-popover__progress">{t('tour.progress', { n: tour.index + 1, total: tour.total })}</span>
        </div>
        <p className="tour-popover__body">{t(`${step.text}.body` as MessageKey)}</p>
        <div className="tour-popover__actions">
          {!last && (
            <button type="button" className="tour-button tour-button--quiet" onClick={tour.end} data-testid="tour-skip">
              {t('tour.skip')}
            </button>
          )}
          {tour.index > 0 && (
            <button type="button" className="tour-button" onClick={tour.back} data-testid="tour-back">
              {t('tour.back')}
            </button>
          )}
          <button ref={primary} type="button" className="tour-button tour-button--primary" onClick={last ? tour.end : tour.next} data-testid="tour-next">
            {last ? t('tour.finish') : t('tour.next')}
          </button>
        </div>
      </div>
    </div>
  );
}

function FeatureCard({ card, onClose, onTour }: { card: CardId; onClose: () => void; onTour: () => void }) {
  const { rect } = useAnchor(CARD_ANCHORS[card]);
  const { ref, placement } = usePlacement(rect);
  // A hint, not a dialog: the user's next press anywhere else puts it away.
  useEffect(() => {
    const onDown = (event: PointerEvent) => {
      if (!ref.current?.contains(event.target as Node)) onClose();
    };
    document.addEventListener('pointerdown', onDown, true);
    return () => document.removeEventListener('pointerdown', onDown, true);
  }, [ref, onClose]);
  return (
    <div ref={ref} className={popoverClass('tour-card', placement)} style={popoverStyle(placement)} role="status" data-testid="tour-card" data-card={card}>
      <Arrow placement={placement} />
      <div className="tour-popover__head">
        <h2 className="tour-popover__title">{t(`tour.${card}.title`)}</h2>
        <button type="button" className="tour-card__close" onClick={onClose} aria-label={t('common.close')}>
          ×
        </button>
      </div>
      <p className="tour-popover__body">{t(`tour.${card}.body`)}</p>
      <div className="tour-popover__actions">
        <button
          type="button"
          className="tour-button tour-button--link"
          onClick={() => {
            onClose();
            onTour();
          }}
        >
          {t('tour.card_full_tour')}
        </button>
        <button type="button" className="tour-button" onClick={onClose} data-testid="tour-card-close">
          {t('tour.card_got_it')}
        </button>
      </div>
    </div>
  );
}

function TourOffer({ onTake, onLater }: { onTake: () => void; onLater: () => void }) {
  return (
    <div className="tour-offer" role="status" data-testid="tour-offer">
      <span className="tour-offer__text">
        <strong>{t('tour.offer_title')}</strong> {t('tour.offer_text')}
      </span>
      <span className="tour-offer__actions">
        <button type="button" className="tour-button tour-button--primary" onClick={onTake} data-testid="tour-offer-take">
          {t('tour.offer_take')}
        </button>
        <button type="button" className="tour-button" onClick={onLater} data-testid="tour-offer-later">
          {t('tour.offer_later')}
        </button>
      </span>
    </div>
  );
}

/** Points at the header's Take a tour once the offer is declined; any click or a few seconds closes it. */
function TourTip({ onClose }: { onClose: () => void }) {
  const { rect } = useAnchor('[data-tour-start]');
  useEffect(() => {
    const timer = window.setTimeout(onClose, 6000);
    // Not the click that declined the offer: that one is still being dispatched.
    const frame = requestAnimationFrame(() => document.addEventListener('click', onClose, { once: true }));
    return () => {
      window.clearTimeout(timer);
      cancelAnimationFrame(frame);
      document.removeEventListener('click', onClose);
    };
  }, [onClose]);
  if (rect === null) return null;
  const left = Math.max(12, Math.min(rect.left + rect.width / 2 - 24, window.innerWidth - 232));
  return (
    <div className="tour-tip" style={{ left, top: rect.top + rect.height + 12 }} role="status" data-testid="tour-tip">
      <span className="tour-tip__arrow" style={{ left: rect.left + rect.width / 2 - left }} aria-hidden="true" />
      {t('tour.tip')}
    </div>
  );
}


/**
 * Holds one of the header's menus (a `<details>`, templates/header.html) open while `open`. The
 * header is the server's markup, outside this app, so this sets its `open` and closes it after.
 */
function useHeaderMenuOpen(selector: string, open: boolean) {
  useEffect(() => {
    if (!open) return;
    const menu = document.querySelector<HTMLDetailsElement>(selector);
    if (!menu) return;
    menu.open = true;
    return () => {
      menu.open = false;
    };
  }, [selector, open]);
}