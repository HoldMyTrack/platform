import type { Map as MapLibreMap } from 'maplibre-gl';
import type { MapMode } from '../map/mapMode';
import type { Overlays } from '../map/overlays';
import type { SpotCategory } from '../map/spots';
import type { Flavor } from '../map/style';
import { BasemapToggle } from './BasemapToggle';
import { MapModeToggle } from './MapModeToggle';
import { OverlaysMenu } from './OverlaysMenu';
import { ShowInArea } from './ShowInArea';
import { ZoomLevelNotice } from './ZoomLevelNotice';
import { t } from '../i18n';

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
  spotsShown: readonly SpotCategory[];
  /** The tour holds the Layers menu open (docs/SPEC.md FR-4.18). */
  layersOpen?: boolean;
}

/** The controls over the map's top edge: the mode toggle, Layers, Satellite, their notices, and Show in this area. */
export function MapControls({ map, mode, onModeChange, overlays, onOverlaysChange, flavor, satelliteAvailable, coverageRendering, basemapUnreachable, spotsShown, layersOpen = false }: MapControlsProps) {
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
        {mode !== 'normal' && coverageRendering && (
          <div className="coverage-notice" role="status" data-testid="coverage-notice">
            <span className="coverage-notice__pill">{t('map.coverage_updating')}</span>
          </div>
        )}
        {map && <ZoomLevelNotice map={map} mode={mode} />}
      </div>
      {map && <ShowInArea map={map} categories={spotsShown} />}
    </>
  );
}
