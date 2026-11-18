import { Suspense, type RefObject } from 'react';
import type { Map as MapLibreMap } from 'maplibre-gl';
import type { ExportControls } from '../map/useExportFlow.ts';
import { ExportControl } from './ExportControl.tsx';
import { lazyChunk } from '../lazyChunk.ts';

// The viewfinder loads when Export is first opened: its control is on every map, the viewfinder
// on few (lazyChunk.ts).
const ExportViewfinder = lazyChunk(() => import('./ExportViewfinder.tsx').then((m) => m.ExportViewfinder));

/** The map image export (FR-4.7): its map control, and the viewfinder while it's open (useExportFlow.ts). */
export function MapExport({ map, container, exporter }: { map: MapLibreMap; container: RefObject<HTMLDivElement | null>; exporter: ExportControls }) {
  const { flow } = exporter;
  return (
    <>
      <ExportControl map={map} active={flow.stage !== 'idle'} onOpen={exporter.toggle} />
      {flow.stage !== 'idle' && (
        <Suspense fallback={null}>
        <ExportViewfinder
          map={map}
          containerRef={container}
          preset={flow.preset}
          customSize={flow.customSize}
          maxSidePx={exporter.maxSidePx}
          window={flow.window}
          busy={flow.stage === 'capturing'}
          error={exporter.error}
          onWindowChange={exporter.moveWindow}
          onChoiceChange={exporter.changeChoice}
          onCapture={() => void exporter.capture()}
          onCancel={exporter.cancel}
          showStats={exporter.showStats}
          statsOffered={exporter.statsOffered}
          onShowStatsChange={exporter.setShowStats}
          stats={exporter.stats}
        />
        </Suspense>
      )}
    </>
  );
}
