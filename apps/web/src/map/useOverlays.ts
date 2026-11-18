import { useCallback, useMemo, useState } from 'react';
import type { BikePathOverlays } from './bikePathsGroup.ts';
import { satelliteSource } from './config.ts';
import { satelliteOffered } from './imageryOffered.ts';
import { loadOverlays, saveOverlays, type Overlays } from './overlays.ts';
import { useImageryStatus } from './useImageryStatus.ts';

interface OverlayChoices {
  overlays: Overlays;
  change: (next: Overlays) => void;
  /** The paths drawn: each picked, while the Layers checkbox is on. */
  paths: BikePathOverlays;
  /** The basemap's roads are drawn: picked, while the Layers checkbox is on. */
  roads: boolean;
  /** Satellite is offered: the deployment configures imagery and the server hasn't paused it
   *  (FR-4.10, imageryOffered.ts). */
  satelliteAvailable: boolean;
  /** Imagery is drawn: available and picked, whatever was saved; a choice saved while it's
   *  paused comes back with it. */
  satellite: boolean;
}

/** The Satellite button, the Layers menu's roads and paths and the Places menu's Spots categories, remembered per browser (overlays.ts). */
export function useOverlays(): OverlayChoices {
  const [overlays, setOverlays] = useState<Overlays>(loadOverlays);
  const change = useCallback((next: Overlays) => {
    saveOverlays(next);
    setOverlays(next);
  }, []);
  const paths = useMemo(
    () => ({
      bikePaths: overlays.enabled && overlays.bikePaths,
      sharedPaths: overlays.enabled && overlays.sharedPaths,
      mtbTrails: overlays.enabled && overlays.mtbTrails,
    }),
    [overlays.enabled, overlays.bikePaths, overlays.sharedPaths, overlays.mtbTrails],
  );
  const configured = satelliteSource() !== null;
  const satelliteAvailable = satelliteOffered(configured, useImageryStatus(configured));
  return { overlays, change, paths, roads: overlays.enabled && overlays.roads, satelliteAvailable, satellite: satelliteAvailable && overlays.satellite };
}
