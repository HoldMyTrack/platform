import type { Map as MapLibreMap } from 'maplibre-gl';
import type { MapMode } from '../map/mapMode';
import type { Overlays } from '../map/overlays';
import type { SpotCategory } from '../map/spots';
import type { Flavor } from '../map/style';
import type { Explored } from '../map/useCoverageRefresh';
import { BasemapToggle } from './BasemapToggle';
import { MapModeToggle } from './MapModeToggle';
import { OverlaysMenu } from './OverlaysMenu';
import { ShowInArea } from './ShowInArea';
import { FogLevelMenu } from './FogLevelMenu';
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
  /** The places of each Fog level explored, which Fog's level control counts. */
  explored: Explored | null;
  /** The basemap can't be reached (basemapStatus.ts): its notice shows under the toggles. */
  basemapUnreachable: boolean;
  /** Satellite is on and its imagery failed to load (satelliteStatus.ts): its notice shows under the toggles. */
  satelliteFailed: boolean;
  spotsShown: readonly SpotCategory[];
  /** The tour holds the Layers menu open (docs/SPEC.md FR-4.18). */
  layersOpen?: boolean;
  /** How many the area holds when the list, and so the map, was cut at its limit (docs/SPEC.md FR-5.19). */
  capped: { shown: number; total: number } | null;
}

/** The controls over the map's top edge: the mode toggle with Fog's level menu, Layers,
 *  Satellite, their notices, and the pills under them: places' Show in this area, and the area's cap. */
export function MapControls({ map, mode, onModeChange, overlays, onOverlaysChange, flavor, satelliteAvailable, coverageRendering, explored, basemapUnreachable, satelliteFailed, spotsShown, layersOpen = false, capped }: MapControlsProps) {
  return (
    <>
      <div className="map-toggles">
        <MapModeToggle mode={mode} onChange={onModeChange} fogMenu={map && <FogLevelMenu map={map} explored={explored} />} />
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
        <ZoomLevelNotice mode={mode} />
      </div>
      <div className="map-area">
        {map && <ShowInArea map={map} categories={spotsShown} />}
        {capped && (
          <span className="show-in-area__status show-in-area__status--capped" role="status" data-testid="area-capped">
            {t('area.capped', { shown: capped.shown.toLocaleString(lang), total: capped.total.toLocaleString(lang) })}
          </span>
        )}
      </div>
    </>
  );
}
