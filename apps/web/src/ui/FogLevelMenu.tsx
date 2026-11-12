import { useEffect, useRef, useState } from 'react';
import type { Map as MapLibreMap } from 'maplibre-gl';
import { ChevronDown, Lock } from 'lucide-react';
import { currentLayerState, currentLayers, updateLayers } from '../map/applyLayers';
import { exploredCount, fogLevelInView, fogLevelPick, levelLabelKey } from '../map/fogLevels';
import type { Explored } from '../map/useCoverageRefresh';
import { hasKey, lang, t } from '../i18n';

export interface FogLevelMenuProps {
  map: MapLibreMap;
  /** The places of each level the account has explored, which the menu counts. */
  explored: Explored | null;
}

/**
 * Fog's level, in the mode toggle while Fog is on (docs/SPEC.md FR-4.2): the button names the
 * level in view, changing as the zoom does, and a lock when one is locked; it opens a menu of Auto,
 * which follows the zoom, and every level with how many of its places the account has explored.
 * Picking a level locks it at every zoom, zooming out to its band when zoomed in past it
 * (fogLevels.ts), until Auto is picked. The lock lives in the map's layer state, so it outlasts a
 * style swap and a trip out of Fog, and a reload releases it. Open and close as the Layers menu.
 */
export function FogLevelMenu({ map, explored }: FogLevelMenuProps) {
  const [zoom, setZoom] = useState(() => map.getZoom());
  const [locked, setLocked] = useState<string | null>(() => currentLayerState(map).fogLevel ?? null);
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  // The document arrives after the map: redraw once it's applied.
  const [, setApplied] = useState(0);

  useEffect(() => {
    const onZoom = () => setZoom(map.getZoom());
    const onStyle = () => setApplied((n) => n + 1);
    map.on('zoom', onZoom);
    map.on('styledata', onStyle);
    return () => {
      map.off('zoom', onZoom);
      map.off('styledata', onStyle);
    };
  }, [map]);

  useEffect(() => {
    updateLayers(map, { fogLevel: locked });
  }, [map, locked]);

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

  const levels = currentLayers(map)?.levels ?? [];
  const label = (level: string) => {
    const key = levelLabelKey(level, levels.find((l) => l.level === level)?.word, hasKey);
    return hasKey(key) ? t(key) : level;
  };
  const inView = fogLevelInView(levels, zoom, locked);

  const pick = (level: string | null) => {
    setOpen(false);
    if (level === null) {
      setLocked(null);
      return;
    }
    if (level === locked) return;
    const next = fogLevelPick(levels, map.getZoom(), locked, level);
    setLocked(next.locked);
    if (next.zoom !== null) map.easeTo({ zoom: next.zoom });
  };

  return (
    <div className="fog-level-menu" ref={ref}>
      <button
        type="button"
        className="map-mode-toggle__btn map-mode-toggle__btn--active fog-level-menu__btn"
        aria-pressed="true"
        aria-haspopup="true"
        aria-expanded={open}
        onClick={() => setOpen((o) => !o)}
        data-testid="fog-level-menu"
      >
        {t('map.mode_fog')}
        {levels.length > 0 && <span className="fog-level-menu__level">· {label(inView)}</span>}
        {locked !== null && <Lock size={12} aria-label={t('map.fog.level.locked')} />}
        <ChevronDown size={14} aria-hidden="true" />
      </button>
      {open && levels.length > 0 && (
        <div className="overlays-menu__panel" role="dialog" aria-label={t('map.fog.level')}>
          <fieldset className="overlays-menu__group">
            <legend>{t('map.fog.level')}</legend>
            <label className="overlays-menu__item">
              <input type="radio" name="fog-level" checked={locked === null} onChange={() => pick(null)} />
              <span>
                {t('map.fog.level.auto')} <span className="fog-level-menu__hint">{t('map.fog.level.auto_hint')}</span>
              </span>
            </label>
            {levels.map(({ level }) => {
              const count = explored ? exploredCount(explored, level) : null;
              return (
                <label key={level} className="overlays-menu__item">
                  <input type="radio" name="fog-level" checked={locked === level} onChange={() => pick(level)} />
                  <span>{label(level)}</span>
                  {count !== null && <span className="fog-level-menu__count">{count.toLocaleString(lang)}</span>}
                </label>
              );
            })}
          </fieldset>
        </div>
      )}
    </div>
  );
}
