import { useEffect, useRef, useState } from 'react';
import { pickedCount, type Overlays } from '../map/overlays';
import { ChevronDown, Layers } from 'lucide-react';
import { SPOT_CATEGORIES, type SpotCategory } from '../map/spots';
import { getTileVersion } from '../map/coverageVersion';
import { groupOf, type LegendEntry } from '../map/mapLayers';
import type { Flavor } from '../map/style';
import { webLayers } from '../map/webLayers';
import { t } from '../i18n';
import type { MessageKey } from '../i18n/en';

export interface OverlaysMenuProps {
  overlays: Overlays;
  onChange: (next: Overlays) => void;
  /** The basemap's flavor, whose layers document gives the legend. */
  flavor: Flavor;
  /** Held open from outside, whatever the button says: the tour's Layers step. */
  forceOpen?: boolean;
}

/** The bike-paths group's legend entries (bikePathsGroup.ts). */
type PathKind = 'bikePaths' | 'sharedPaths' | 'mtbTrails' | 'trails' | 'tracks';

/** How wide the legend draws a line; the dash scales with it, as on the map. */
const SWATCH_WIDTH = 3;

/** A short sample of a kind of path, in the color and dash the layers document's legend gives. */
function PathSwatch({ entry }: { entry: LegendEntry | undefined }) {
  if (!entry) return null;
  const { color, dash } = entry;
  return (
    <svg className="overlays-menu__swatch" width="24" height="8" viewBox="0 0 24 8" aria-hidden="true">
      <line
        x1="2"
        y1="4"
        x2="22"
        y2="4"
        stroke={color}
        strokeWidth={SWATCH_WIDTH}
        strokeLinecap={dash ? 'butt' : 'round'}
        strokeDasharray={dash?.map((d) => d * SWATCH_WIDTH).join(' ')}
      />
    </svg>
  );
}

const CATEGORY_LABELS: Record<SpotCategory, MessageKey> = {
  playground: 'overlays.playgrounds',
  dog_park: 'overlays.dog_parks',
  monument: 'overlays.monuments',
  viewpoint: 'overlays.viewpoints',
  waterfall: 'overlays.waterfalls',
  history: 'overlays.history',
};

/**
 * The Layers dropdown beside the map-mode toggle (IMPLEMENTATION.md §4.24, §4.25): layers picked
 * over any mode, in three groups — Map (Roads, FR-4.15), Paths (Bike paths, Shared paths and Mountain bike trails, FR-4.13) and Points of interest
 * (each Spots category, FR-15.2). The same open/close rules as the Activities panel's Type
 * dropdown: the button toggles it, and a press outside or Escape closes it. The button shows how
 * many are picked, and the checkbox before it shows or hides all of them at once, keeping the
 * picks; picking one while it's off turns it back on, or the pick would seem to do nothing.
 */
export function OverlaysMenu({ overlays, onChange, flavor, forceOpen = false }: OverlaysMenuProps) {
  const [picked, setOpen] = useState(false);
  const open = picked || forceOpen;
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const onPointerDown = (event: PointerEvent) => {
      if (!ref.current?.contains(event.target as Node)) setOpen(false);
    };
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') setOpen(false);
    };
    document.addEventListener('pointerdown', onPointerDown);
    document.addEventListener('keydown', onKeyDown);
    return () => {
      document.removeEventListener('pointerdown', onPointerDown);
      document.removeEventListener('keydown', onKeyDown);
    };
  }, [open]);

  // `on`: whether this change picks something, which turns the checkbox back on.
  const change = (patch: Partial<Overlays>, on: boolean) =>
    onChange({ ...overlays, ...patch, enabled: on || overlays.enabled });
  const toggleCategory = (category: SpotCategory) => {
    const on = overlays.spots.includes(category);
    change({ spots: SPOT_CATEGORIES.filter((c) => (c === category ? !on : overlays.spots.includes(c))) }, !on);
  };
  const togglePath = (kind: 'bikePaths' | 'sharedPaths' | 'mtbTrails') => change({ [kind]: !overlays[kind] }, !overlays[kind]);
  const legend = groupOf(webLayers(flavor, getTileVersion()), 'bike-paths')?.legend ?? {};
  const count = pickedCount(overlays);
  const shown = overlays.enabled && count > 0;

  const item = (id: string, label: string, checked: boolean, onToggle: () => void, swatch?: PathKind) => (
    <label key={id} htmlFor={id} className="overlays-menu__item">
      <input id={id} type="checkbox" checked={checked} onChange={onToggle} />
      <span>{label}</span>
      {swatch && <PathSwatch entry={legend[swatch]} />}
    </label>
  );

  return (
    <div className="map-mode-toggle overlays-menu" ref={ref} data-testid="map-overlays">
      <label className="overlays-menu__master" title={count === 0 ? t('overlays.master_empty') : undefined}>
        <input
          id="overlay-master"
          type="checkbox"
          aria-label={t('overlays.master')}
          checked={overlays.enabled}
          disabled={count === 0}
          onChange={() => onChange({ ...overlays, enabled: !overlays.enabled })}
        />
      </label>
      <button
        type="button"
        className={shown ? 'map-mode-toggle__btn map-mode-toggle__btn--active' : 'map-mode-toggle__btn'}
        aria-haspopup="true"
        aria-expanded={open}
        onClick={() => setOpen((o) => !o)}
      >
        <Layers size={14} aria-hidden="true" />
        {t('map.overlays')}
        {count > 0 && <span className={shown ? 'overlays-menu__count' : 'overlays-menu__count overlays-menu__count--off'}>{count}</span>}
        <ChevronDown size={14} aria-hidden="true" />
      </button>
      {open && (
        <div className="overlays-menu__panel" role="dialog" aria-label={t('map.overlays')}>
          <fieldset className="overlays-menu__group">
            <legend>{t('overlays.map')}</legend>
            {item('overlay-roads', t('overlays.roads'), overlays.roads, () => change({ roads: !overlays.roads }, !overlays.roads))}
          </fieldset>
          <fieldset className="overlays-menu__group">
            <legend>{t('overlays.paths')}</legend>
            {item('overlay-bike-paths', t('overlays.bike_paths'), overlays.bikePaths, () => togglePath('bikePaths'), 'bikePaths')}
            {item('overlay-shared-paths', t('overlays.shared_paths'), overlays.sharedPaths, () => togglePath('sharedPaths'), 'sharedPaths')}
            {item('overlay-mtb-trails', t('overlays.mtb_trails'), overlays.mtbTrails, () => togglePath('mtbTrails'), 'mtbTrails')}
            {/* Trails and tracks have no entry: they're part of the map (FR-4.13), and this says so. */}
            <p className="overlays-menu__always" data-testid="overlays-always">
              {t('overlays.always_shown')}
              <span className="overlays-menu__key">
                <PathSwatch entry={legend.trails} />
                {t('overlays.trails')}
              </span>
              <span className="overlays-menu__key">
                <PathSwatch entry={legend.tracks} />
                {t('overlays.dirt_tracks')}
              </span>
            </p>
          </fieldset>
          <fieldset className="overlays-menu__group">
            <legend>{t('overlays.places')}</legend>
            {SPOT_CATEGORIES.map((category) =>
              item(`overlay-spots-${category}`, t(CATEGORY_LABELS[category]), overlays.spots.includes(category), () =>
                toggleCategory(category),
              ),
            )}
          </fieldset>
        </div>
      )}
    </div>
  );
}