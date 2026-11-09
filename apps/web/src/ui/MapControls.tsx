import type { Map as MapLibreMap } from 'maplibre-gl';
import type { MapMode } from '../map/mapMode';
import type { Overlays } from '../map/overlays';
import type { SpotCategory } from '../map/spots';
import type { Flavor } from '../map/style';
import { BasemapToggle } from './BasemapToggle';
import { MapPin } from 'lucide-react';
import { MapModeToggle } from './MapModeToggle';
import { OverlaysMenu } from './OverlaysMenu';
import { ShowInArea } from './ShowInArea';
import { ZoomLevelNotice } from './ZoomLevelNotice';
import { lang, t } from '../i18n';

export interface MapControlsProps {
  map: MapLibreMap | null;
  mode: MapMode;
  onModeChange: (mode: MapMode) => void;
  overlays: Overlays;
  onOverlaysChange: (next: Overlays) => void;
  flavor: Flavor;
  satelliteAvailable: boolean;
  /** Fog and Heatmap are being re-rendered: their notice shows under the toggles. */
  coverageRendering: boolean;
  /** The basemap can't be reached (basemapStatus.ts): its notice shows under the toggles. */
  basemapUnreachable: boolean;
  /** Satellite is on and its imagery failed to load (satelliteStatus.ts): its notice shows under the toggles. */
  satelliteFailed: boolean;
  spotsShown: readonly SpotCategory[];
  /** The tour holds the Layers menu open (docs/SPEC.md FR-4.18). */
  layersOpen?: boolean;
  /** The activity list's area (docs/SPEC.md FR-5.19): its button from zoom 4 to 10 once the map
   *  moved, and how many the area holds when the list was cut at its limit. */
  area: { button: boolean; onLoad: () => void; capped: { shown: number; total: number } | null };
}

/** The controls over the map's top edge: the mode toggle, Layers, Satellite, their notices, and
 *  the area's pills: Show activities in this area, places' Show in this area, the list's cap. */
export function MapControls({ map, mode, onModeChange, overlays, onOverlaysChange, flavor, satelliteAvailable, coverageRendering, basemapUnreachable, satelliteFailed, spotsShown, layersOpen = false, area }: MapControlsProps) {
  return (
    <>
      <div className="map-toggles">
        <MapModeToggle mode={mode} onChange={onModeChange} />
        {/* Layers switch on and off over any mode; they're not a fourth mode. */}
        <OverlaysMenu overlays={overlays} onChange={onOverlaysChange} flavor={flavor} forceOpen={layersOpen} />
        {satelliteAvailable && <BasemapToggle satellite={overlays.satellite} onChange={(on) => onOverlaysChange({ ...overlays, satellite: on })} />}
        {/* On lines of their own under the toggles, however many rows they wrap to. */}
        {basemapUnreachable && (
          <div className="coverage-notice" role="alert" data-testid="basemap-notice">
            <span className="coverage-notice__pill coverage-notice__pill--failed">{t('map.basemap_unreachable')}</span>
          </div>
        )}
        {satelliteFailed && (
          <div className="coverage-notice" role="alert" data-testid="satellite-notice">
            <span className="coverage-notice__pill coverage-notice__pill--failed">{t('map.satellite_failed')}</span>
          </div>
        )}
        {mode !== 'normal' && coverageRendering && (
          <div className="coverage-notice" role="status" data-testid="coverage-notice">
            <span className="coverage-notice__pill">{t('map.coverage_updating')}</span>
          </div>
        )}
        {map && <ZoomLevelNotice map={map} mode={mode} />}
      </div>
      <div className="map-area">
        {area.button && (
          <button type="button" className="show-in-area__btn" onClick={area.onLoad} data-testid="activities-in-area">
            <MapPin size={14} aria-hidden="true" />
            {t('area.show_activities')}
          </button>
        )}
        {map && <ShowInArea map={map} categories={spotsShown} />}
        {area.capped && (
          <span className="show-in-area__status show-in-area__status--capped" role="status" data-testid="area-capped">
            {t('area.capped', { shown: area.capped.shown.toLocaleString(lang), total: area.capped.total.toLocaleString(lang) })}
          </span>
        )}
      </div>
    </>
  );
}
