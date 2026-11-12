import { useEffect, useState } from 'react';
import type { MapMode } from '../map/mapMode';
import { t } from '../i18n';

/** How long the notice stays before it fades. */
const SHOW_MS = 3000;

/**
 * Heatmap's notice: what its colours mean, on entering it (`SPEC.md` FR-4.3), in a pill under the
 * mode toggle (MapView renders it in `.map-toggles`, on a line of its own below however many rows
 * those wrap to), faded after SHOW_MS. Heatmap reads the same at every zoom, so a zoom doesn't
 * bring it back. Fog names its level in FogLevelMenu.
 */
export function ZoomLevelNotice({ mode }: { mode: MapMode }) {
  const [visible, setVisible] = useState(false);
  const shown = mode === 'heatmap';

  useEffect(() => {
    if (!shown) {
      setVisible(false);
      return;
    }
    setVisible(true);
    const timer = window.setTimeout(() => setVisible(false), SHOW_MS);
    return () => window.clearTimeout(timer);
  }, [shown]);

  return (
    <div className={`zoom-level-notice${visible ? ' zoom-level-notice--visible' : ''}`} role="status" data-testid="zoom-level-notice">
      <span className="zoom-level-notice__pill">{t('map.level.heatmap')}</span>
    </div>
  );
}
