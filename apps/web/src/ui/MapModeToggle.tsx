import { Fragment, type ReactNode } from 'react';
import type { MapMode } from '../map/mapMode';
import { t } from '../i18n';

const MODES: readonly MapMode[] = ['normal', 'fog'];
const LABELS: Record<MapMode, 'map.mode_normal' | 'map.mode_fog'> = {
  normal: 'map.mode_normal',
  fog: 'map.mode_fog',
};

/** Normal or Fog (docs/SPEC.md FR-4.3). While Fog is on, `fogMenu` stands in for its button: the
 *  level in view and the menu of levels (FogLevelMenu). */
export function MapModeToggle({ mode, onChange, fogMenu }: { mode: MapMode; onChange: (mode: MapMode) => void; fogMenu?: ReactNode }) {
  return (
    <div className="map-mode-toggle" role="group" aria-label={t('map.mode')} data-testid="map-mode-toggle">
      {MODES.map((value) => (
        <Fragment key={value}>
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
