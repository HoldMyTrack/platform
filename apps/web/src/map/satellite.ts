import type { Map as MapLibreMap } from 'maplibre-gl';
import {
  SATELLITE_DIMS_METADATA,
  SATELLITE_HIDES_METADATA,
  SATELLITE_LAYER_ID,
  SATELLITE_ROAD_OPACITY,
} from './style';

/**
 * The Satellite button (BasemapToggle.tsx, docs/SPEC.md FR-4.14, overlays.ts): shows the satellite
 * imagery, hides the basemap's background and area fills over it and draws the roads at
 * `SATELLITE_ROAD_OPACITY`, or the reverse; boundaries and place labels stay as they are either
 * way, and whether the roads show at all is the Layers menu's (overlays.ts).
 * Diffs before setting, like paths.ts: reattachOverlays calls this on every 'styledata', and an
 * unconditional setLayoutProperty would keep re-firing it (docs/DEVELOPMENT.md). A no-op when
 * the style has no imagery (no deployment config). MapLibre CORS-fetches imagery tiles, since
 * WebGL can't draw a tainted image, so they never taint the export's canvas either.
 */
export function setSatelliteVisible(map: MapLibreMap, on: boolean): void {
  if (!map.getLayer(SATELLITE_LAYER_ID)) return;
  const set = (id: string, visible: boolean) => {
    const next = visible ? 'visible' : 'none';
    if (map.getLayoutProperty(id, 'visibility') !== next) map.setLayoutProperty(id, 'visibility', next);
  };
  set(SATELLITE_LAYER_ID, on);
  const metadata = map.getStyle().metadata as Record<string, unknown> | undefined;
  // From the metadata, not satelliteHiddenLayerIds over the live map: that would take every
  // background layer, Heatmap's wash among them (coverageGroup.ts), and show it in every mode.
  const hidden = metadata?.[SATELLITE_HIDES_METADATA];
  for (const id of Array.isArray(hidden) ? (hidden as string[]) : []) {
    if (map.getLayer(id)) set(id, !on);
  }
  // From the metadata, not satelliteDimmedLayerIds: a road already dimmed sets an opacity, which
  // is exactly what that function leaves out. Off resets to the default, which those layers had.
  const dimmed = metadata?.[SATELLITE_DIMS_METADATA];
  const opacity = on ? SATELLITE_ROAD_OPACITY : undefined;
  for (const id of Array.isArray(dimmed) ? (dimmed as string[]) : []) {
    if (map.getLayer(id) && map.getPaintProperty(id, 'line-opacity') !== opacity) map.setPaintProperty(id, 'line-opacity', opacity);
  }
}
