import { Fragment, type ReactNode } from 'react';
import type { MapMode } from '../map/mapMode';
import { t } from '../i18n';

const MODES: readonly MapMode[] = ['normal', 'fog', 'heatmap'];
const LABELS: Record<MapMode, 'map.mode_normal' | 'map.mode_fog' | 'map.mode_heatmap'> = {
  normal: 'map.mode_normal',
  fog: 'map.mode_fog',
  heatmap: 'map.mode_heatmap',
};

/** Normal, Fog and Heatmap: one at a time (docs/SPEC.md FR-4.4). While Fog is on, `fogMenu`
 *  stands in for its button: the level in view and the menu of levels (FogLevelMenu). */
export function MapModeToggle({ mode, onChange, fogMenu }: { mode: MapMode; onChange: (mode: MapMode) => void; fogMenu?: ReactNode }) {
  return (
    <div className="map-mode-toggle" role="group" aria-label={t('map.mode')} data-testid="map-mode-toggle">
      {MODES.map((value) => (
        <Fragment key={value}>
          {/* Normal on one side, the two coverage views on the other. */}
          {value === 'fog' && <span className="map-mode-toggle__divider" aria-hidden="true" />}
          {value === 'fog' && mode === 'fog' && fogMenu ? (
            fogMenu
          ) : (
            <button
              type="button"
              className={mode === value ? 'map-mode-toggle__btn map-mode-toggle__btn--active' : 'map-mode-toggle__btn'}
              aria-pressed={mode === value}
              onClick={() => onChange(value)}
            >
              {t(LABELS[value])}
            </button>
          )}
        </Fragment>
      ))}
    </div>
  );
}
