import { useCallback, useEffect, useRef } from 'react';
import type { Map as MapLibreMap } from 'maplibre-gl';
import { basemapOrigin, satelliteSource } from './config';
import { applyLayers, currentLayerState, setLayerToggles } from './applyLayers';
import type { BikePathOverlays } from './bikePathsGroup';
import { getTileVersion } from './coverageVersion';
import { webLayers } from './webLayers';
import { setMapMode, type MapMode } from './mapMode';
import { setRoadsVisible } from './mapRoads';
import { setSatelliteVisible } from './satellite';
import { ensureSpotsLayer, type SpotCategory } from './spots';
import { buildStyle, type Flavor } from './style';
import { setTrackBands } from './trackBands';
import { attachTrackInteractivity, refreshTrackLayer, trackQuery } from './tracks';
import type { ActivityQuery, ActivityTrackMetrics } from '../api';
import { lang } from '../i18n';

export interface MapLayersInputs {
  initialFlavor: Flavor;
  flavor: Flavor;
  /** Satellite is on: its imagery layer is requested. */
  satellite: boolean;
  /** The map looks like Satellite, which failed imagery doesn't (satelliteStatus.ts). */
  satelliteLook: boolean;
  /** The basemap's roads are drawn (overlays.ts). */
  roads: boolean;
  mode: MapMode;
  /** The Edit window's Track tab has the map. */
  editingTrack: boolean;
  paths: BikePathOverlays;
  spotsShown: readonly SpotCategory[];
  tracksQuery: ActivityQuery;
  mapHiddenIds: ReadonlySet<string>;
  /** The tracks drawn bold (selection.ts's boldTracks). */
  boldIds: readonly string[];
  /** The focused activity's metrics, if its bands are drawn. */
  bands: ActivityTrackMetrics | null;
}

/**
 * The app's own layers over the basemap: added on every style load, since `setStyle` keeps the
 * camera but drops custom layers, and kept in step with the mode, paths, satellite, roads and the
 * tracks' query between loads. A theme change swaps the style in place.
 */
export function useMapLayers(map: MapLibreMap | null, inputs: MapLayersInputs): void {
  const { initialFlavor, flavor, satellite, satelliteLook, roads, mode, editingTrack, paths, spotsShown, tracksQuery, mapHiddenIds, boldIds, bands } = inputs;

  // Points the tracks source at the new query, as a new URL.
  useEffect(() => {
    if (map) refreshTrackLayer(map, tracksQuery);
  }, [map, tracksQuery]);

  const reattach = useCallback(
    (instance: MapLibreMap) => {
      // Everything the layers document draws, in its order (mapLayers.ts), with the state the
      // last style had: a style load mid-mode would otherwise drop to Normal and un-hide every
      // hidden track.
      const state = currentLayerState(instance);
      applyLayers(instance, webLayers(flavor, getTileVersion()), {
        ...state,
        mode,
        satellite: satelliteLook,
        toggles: { ...state.toggles, ...paths },
        vars: { ...state.vars, hidden: [...mapHiddenIds], focused: [...boldIds] },
        queries: { ...state.queries, tracks: trackQuery(tracksQuery) },
      });
      attachTrackInteractivity(instance);
      // Spots last, above the basemap's labels too (spots.ts).
      ensureSpotsLayer(instance, spotsShown);
      setMapMode(instance, mode, satelliteLook, editingTrack);
      setSatelliteVisible(instance, satellite, satelliteLook);
      setRoadsVisible(instance, roads);
      // The band source is recreated empty.
      if (bands) setTrackBands(instance, bands);
    },
    [flavor, satellite, satelliteLook, roads, mode, editingTrack, paths, spotsShown, mapHiddenIds, tracksQuery, bands, boldIds],
  );

  useEffect(() => {
    if (!map) return;
    const onStyleData = () => reattach(map);
    map.on('styledata', onStyleData);
    // Trap: `map` is set after 'load', and a later 'styledata' isn't guaranteed until a setStyle,
    // so attach directly too or overlays would wait for a theme switch.
    reattach(map);
    return () => {
      map.off('styledata', onStyleData);
    };
  }, [map, reattach]);

  // Declared after the styledata effect on purpose: effects run in order, so the reattach against
  // the outgoing style happens before setStyle starts loading the new one. `diff: false` drops
  // every custom source, so no fog source keeps the other theme's URL.
  const appliedFlavor = useRef(initialFlavor);
  useEffect(() => {
    if (!map || appliedFlavor.current === flavor) return;
    appliedFlavor.current = flavor;
    map.setStyle(buildStyle({ flavor, origin: basemapOrigin(), satellite: satelliteSource(), satelliteOn: satellite, lang, globe: true }), {
      diff: false,
    });
    // Only a flavor change swaps the style; the Satellite button flips layers in place (below).
  }, [map, flavor]);

  // Mode, paths, satellite and roads changes between style loads flip the layers in place.
  useEffect(() => {
    if (!map) return;
    setMapMode(map, mode, satelliteLook, editingTrack);
  }, [map, mode, satelliteLook, editingTrack]);

  useEffect(() => {
    if (!map) return;
    setLayerToggles(map, paths);
  }, [map, paths]);

  useEffect(() => {
    if (!map) return;
    setSatelliteVisible(map, satellite, satelliteLook);
  }, [map, satellite, satelliteLook]);

  useEffect(() => {
    if (!map) return;
    setRoadsVisible(map, roads);
  }, [map, roads]);
}
