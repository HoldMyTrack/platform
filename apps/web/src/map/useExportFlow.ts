import { useCallback, useMemo, useRef, useState, type RefObject } from 'react';
import type { Map as MapLibreMap } from 'maplibre-gl';
import { exportFlowReducer, type ExportEvent, type ExportFlow } from './exportFlow';
import { exportFramedImage, maxExportSide, type ExportViewState } from './exportMap';
import { DEFAULT_CUSTOM_SIZE, outputSize, usableCustomSize, type CustomSizeId, type ExportChoice } from './exportViewfinder';
import type { Rect } from './exportViewfinder';
import { t } from '../i18n';
import { todayIn } from '../ui/dateMath';
import { activityTimeZone } from '../ui/timeZone';
import { statsCardRequest, statsOffered } from './exportStats';
import { isDarkBase } from './style';
import { useStatsCard, type StatsCardState } from './useStatsCard';

const SHOW_STATS_KEY = 'hmt.exportShowStats';

/** The Show stats choice this browser last made; off until one is made. */
function loadShowStats(): boolean {
  try {
    return window.localStorage.getItem(SHOW_STATS_KEY) === '1';
  } catch {
    return false;
  }
}

function saveShowStats(show: boolean): void {
  try {
    window.localStorage.setItem(SHOW_STATS_KEY, show ? '1' : '0');
  } catch {
    // A browser that keeps nothing asks again next visit.
  }
}

/** What the stats card is drawn from: the Activities panel's checked set and the open Story. */
export interface ExportStatsSource {
  checked: ReadonlySet<string>;
  storyId: string | null;
}

export interface ExportControls {
  flow: ExportFlow;
  error: string | null;
  maxSidePx: number;
  /** The map control: opens or closes the viewfinder. */
  toggle: () => void;
  changeChoice: (choice: ExportChoice) => void;
  moveWindow: (window: Rect) => void;
  capture: () => Promise<void>;
  cancel: () => void;
  /** Show stats: the box as ticked, and whether it can be (exportStats.ts's statsOffered). */
  showStats: boolean;
  statsOffered: boolean;
  setShowStats: (show: boolean) => void;
  /** The card the frame previews and Export draws. */
  stats: StatsCardState;
}

/** The map image export (FR-4.7): the viewfinder's stages (exportFlow.ts) and the capture of
 *  what [scene] draws into a downloaded PNG. */
export function useExportFlow(
  map: MapLibreMap | null,
  container: RefObject<HTMLDivElement | null>,
  scene: ExportViewState,
  source: ExportStatsSource,
): ExportControls {
  const [flow, setFlow] = useState<ExportFlow>({ stage: 'idle' });
  const dispatch = useCallback((event: ExportEvent) => setFlow((current) => exportFlowReducer(current, event)), []);
  const [error, setError] = useState<string | null>(null);
  // The Custom size last picked, kept for the next time the viewfinder opens in this visit.
  const customSizeRef = useRef<CustomSizeId>(DEFAULT_CUSTOM_SIZE);
  const maxSidePx = useMemo(() => (map ? maxExportSide(map) : 4096), [map]);
  const [showStats, setShowStatsState] = useState(loadShowStats);
  const setShowStats = useCallback((show: boolean) => {
    setShowStatsState(show);
    saveShowStats(show);
  }, []);
  const offered = statsOffered(source.checked, source.storyId);
  const target = flow.stage === 'idle' ? null : outputSize(flow.preset, flow.customSize, flow.window);
  const widthPx = target?.widthPx ?? 0;
  const heightPx = target?.heightPx ?? 0;
  const dark = isDarkBase(scene.flavor, scene.satellite);
  const request = useMemo(
    () => (widthPx > 0 ? statsCardRequest(showStats, source.checked, source.storyId, { widthPx, heightPx }, dark) : null),
    [showStats, source.checked, source.storyId, widthPx, heightPx, dark],
  );
  const stats = useStatsCard(request);

  const toggle = useCallback(() => {
    const el = container.current;
    if (!map || !el) return;
    setError(null);
    dispatch({ type: 'toggle', customSize: usableCustomSize(customSizeRef.current, maxSidePx), container: { width: el.clientWidth, height: el.clientHeight } });
  }, [map, container, maxSidePx, dispatch]);

  const changeChoice = useCallback(
    (choice: ExportChoice) => {
      const el = container.current;
      if (!el) return;
      if (choice.preset === 'custom') customSizeRef.current = choice.customSize;
      dispatch({ type: 'choice', choice, container: { width: el.clientWidth, height: el.clientHeight } });
    },
    [container, dispatch],
  );

  const moveWindow = useCallback((window: Rect) => dispatch({ type: 'window', window }), [dispatch]);

  const capture = useCallback(async () => {
    // Until the card for this frame arrives, Export would draw another than the one previewed.
    if (flow.stage !== 'framing' || !map || !stats.ready) return;
    const { preset, customSize, window: win } = flow;
    dispatch({ type: 'capture' });
    setError(null);
    try {
      const center = map.unproject([win.x + win.w / 2, win.y + win.h / 2]);
      const blob = await exportFramedImage(map, scene, {
        center: { lng: center.lng, lat: center.lat },
        widthPx: win.w,
        heightPx: win.h,
        target: outputSize(preset, customSize, win),
        statsCard: stats.card?.image ?? null,
      });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      // Named for the account's day (FR-1.7), not UTC's: at 8 pm in New York, UTC is tomorrow.
      a.download = `holdmytrack-${todayIn(activityTimeZone(undefined))}.png`;
      document.body.appendChild(a);
      a.click();
      a.remove();
      URL.revokeObjectURL(url);
      dispatch({ type: 'close' });
    } catch (err) {
      // The cause (a canvas or render timeout) is for developers; the user gets a generic message.
      console.error('export failed', err);
      setError(t('export.failed'));
      dispatch({ type: 'failed' });
    }
  }, [flow, map, scene, dispatch, stats]);

  const cancel = useCallback(() => {
    dispatch({ type: 'close' });
    setError(null);
  }, [dispatch]);

  return { flow, error, maxSidePx, toggle, changeChoice, moveWindow, capture, cancel, showStats, statsOffered: offered, setShowStats, stats };
}
