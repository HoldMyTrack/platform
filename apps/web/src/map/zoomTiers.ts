import type { MessageKey } from '../i18n/en';
import type { ZoomTier } from './mapLayers';

/** The level notice's message (ZoomLevelNotice.tsx) for `mode` at `tier`, the tier the served
 *  layers' tiers put the zoom in (mapLayers.ts): Fog's names the tier, since a veil lifted
 *  from a whole country needs explaining; Heatmap reads the same way at every zoom, so it has one
 *  message, and a zoom across a tier doesn't bring it back. */
export function levelNoticeKey(mode: 'fog' | 'heatmap', tier: ZoomTier): MessageKey {
  return mode === 'fog' ? `map.level.fog.${tier}` : 'map.level.heatmap';
}
