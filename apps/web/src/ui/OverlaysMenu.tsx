import { layersCount, toggleLayer, type LayerPick, type Overlays } from '../map/overlays.ts';
import { Layers } from 'lucide-react';
import { getTileVersion } from '../map/coverageVersion.ts';
import { groupOf, type LegendEntry } from '../map/mapLayers.ts';
import type { Flavor } from '../map/style.ts';
import { webLayers } from '../map/webLayers.ts';
import { t } from '../i18n/index.ts';
import { PickItem, PickMenu } from './PickMenu.tsx';

interface OverlaysMenuProps {
  overlays: Overlays;
  onChange: (next: Overlays) => void;
  /** The basemap's flavor, whose layers document gives the legend. */
  flavor: Flavor;
  /** Held open from outside, whatever the button says: the tour's Layers step. */
  forceOpen?: boolean;
}

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

/**
 * The Layers dropdown beside the map-mode toggle (IMPLEMENTATION.md §4.24, §4.25): roads and paths
 * picked over any mode, in two groups, Map (Roads, FR-4.11) and Paths (Bike paths, Shared paths
 * and Mountain bike trails, FR-4.9), with the trails and tracks the map always draws. Picking one
 * while the checkbox is off turns it back on, or the pick would seem to do nothing. Places have a
 * menu of their own (PlacesMenu.tsx).
 */
export function OverlaysMenu({ overlays, onChange, flavor, forceOpen = false }: OverlaysMenuProps) {
  const toggle = (pick: LayerPick) => onChange(toggleLayer(overlays, pick));
  const legend = groupOf(webLayers(flavor, getTileVersion()), 'bike-paths')?.legend ?? {};
  const path = (id: string, label: string, kind: 'bikePaths' | 'sharedPaths' | 'mtbTrails') => (
    <PickItem id={id} label={label} checked={overlays[kind]} onToggle={() => toggle(kind)} after={<PathSwatch entry={legend[kind]} />} />
  );

  return (
    <PickMenu
      testId="map-overlays"
      label={t('map.overlays')}
      icon={<Layers size={14} aria-hidden="true" />}
      count={layersCount(overlays)}
      enabled={overlays.enabled}
      onEnabledChange={(enabled) => onChange({ ...overlays, enabled })}
      masterId="overlay-master"
      masterLabel={t('overlays.master')}
      emptyHint={t('overlays.master_empty')}
      forceOpen={forceOpen}
    >
      <fieldset className="overlays-menu__group">
        <legend>{t('overlays.map')}</legend>
        <PickItem id="overlay-roads" label={t('overlays.roads')} checked={overlays.roads} onToggle={() => toggle('roads')} />
      </fieldset>
      <fieldset className="overlays-menu__group">
        <legend>{t('overlays.paths')}</legend>
        {path('overlay-bike-paths', t('overlays.bike_paths'), 'bikePaths')}
        {path('overlay-shared-paths', t('overlays.shared_paths'), 'sharedPaths')}
        {path('overlay-mtb-trails', t('overlays.mtb_trails'), 'mtbTrails')}
        {/* Trails and tracks have no entry: they're part of the map (FR-4.9), and this says so. */}
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
    </PickMenu>
  );
}
