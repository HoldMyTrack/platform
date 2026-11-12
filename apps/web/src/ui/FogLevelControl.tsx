import { useEffect, useState } from 'react';
import type { Map as MapLibreMap } from 'maplibre-gl';
import { currentLayerState, currentLayers, updateLayers } from '../map/applyLayers';
import { fogLevelInView, fogLevelPick, levelLabelKey } from '../map/fogLevels';
import { hasKey, t, tn } from '../i18n';
import type { Explored } from '../map/useCoverageRefresh';

/**
 * Fog's level control (docs/SPEC.md FR-4.2): "Country | State | County | City | Exact", one per
 * level of the layers document. The level in view follows the zoom and is marked as it changes;
 * picking one locks it at every zoom, zooming out to its band when zoomed in past it, until it
 * is picked again (fogLevels.ts). The lock lives in the map's layer state, so it
 * outlasts a style swap and a trip out of Fog, and a reload releases it. Under it, how many
 * places of each level the account has explored.
 */
export function FogLevelControl({ map, explored }: { map: MapLibreMap; explored: Explored | null }) {
  const [zoom, setZoom] = useState(() => map.getZoom());
  const [locked, setLocked] = useState<string | null>(() => currentLayerState(map).fogLevel ?? null);
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

  const levels = currentLayers(map)?.levels ?? [];
  if (levels.length === 0) return null;
  const inView = fogLevelInView(levels, zoom, locked);

  const pick = (level: string) => {
    const next = fogLevelPick(levels, map.getZoom(), locked, level);
    setLocked(next.locked);
    if (next.zoom !== null) map.easeTo({ zoom: next.zoom });
  };

  return (
    <div className="fog-level-control">
      <div className="fog-level-control__group" role="group" aria-label={t('map.fog.level')} data-testid="fog-level-control">
        {levels.map(({ level, word }) => {
          const key = levelLabelKey(level, word, hasKey);
          const state = level === locked ? ' fog-level-control__btn--locked' : level === inView ? ' fog-level-control__btn--current' : '';
          return (
            <button key={level} type="button" className={`fog-level-control__btn${state}`} aria-pressed={level === locked} onClick={() => pick(level)}>
              {hasKey(key) ? t(key) : level}
            </button>
          );
        })}
      </div>
      {explored && (
        <p className="fog-level-control__explored" data-testid="fog-explored">
          {(['countries', 'regions', 'counties', 'cities'] as const).map((level) => tn(`map.fog.explored.${level}`, explored[level])).join(' · ')}
        </p>
      )}
    </div>
  );
}
