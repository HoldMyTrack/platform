import { useEffect, useRef, useState } from 'react';
import { getTrackInfo, type TrackInfo } from '../api.ts';
import { t } from '../i18n/index.ts';
import { useWindowFocus } from './useWindowFocus.ts';

/** How long a changed target waits, with no further change, before Info reads it. */
const FOLLOW_DELAY_MS = 400;

interface TrackInfoWindowProps {
  /** The toolbar's target: Info follows it while open. */
  trackIds: readonly string[];
  /** The pace bands' colors, slowest first, while the map draws them for this one track; else null. */
  bandColors: readonly string[] | null;
  onClose: () => void;
}

/**
 * The toolbar's Info (docs/SPEC.md FR-5.8): the server's lines for the target (`POST /v2/tracks/info`),
 * the pace bands' legend while the map draws them, and the server's note under them. It floats
 * over the map, at the Edit window's edge and width, instead of a modal dialog, so the legend
 * reads against the bands it explains and the map stays in use. Escape closes it while focus is
 * in it.
 */
export function TrackInfoWindow({ trackIds, bandColors, onClose }: TrackInfoWindowProps) {
  const [loaded, setLoaded] = useState<{ key: string; info: TrackInfo } | null>(null);
  const [failed, setFailed] = useState<{ key: string; message: string } | null>(null);
  const windowRef = useRef<HTMLElement>(null);
  const key = trackIds.join(',');
  useWindowFocus(windowRef);

  // The first read goes at once. A target that changes while Info is open waits for the clicks to
  // pause, so checking rows one by one doesn't spend the account's hourly Info limit
  // (services/server/internal/httpapi/rate_limits.go): a request the client drops still counts.
  const opened = useRef(false);
  useEffect(() => {
    const abort = new AbortController();
    const timer = setTimeout(
      () => {
        getTrackInfo(key.split(','), abort.signal).then(
          (info) => setLoaded({ key, info }),
          (err: unknown) => {
            if (!abort.signal.aborted) setFailed({ key, message: err instanceof Error ? err.message : String(err) });
          },
        );
      },
      opened.current ? FOLLOW_DELAY_MS : 0,
    );
    opened.current = true;
    return () => {
      clearTimeout(timer);
      abort.abort();
    };
  }, [key]);

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key !== 'Escape' || event.defaultPrevented || !windowRef.current?.contains(document.activeElement)) return;
      event.preventDefault();
      onClose();
    };
    document.addEventListener('keydown', onKeyDown);
    return () => document.removeEventListener('keydown', onKeyDown);
  }, [onClose]);

  // What was read for an earlier target stays out of sight while the new one loads.
  const info = loaded?.key === key ? loaded.info : null;
  const error = failed?.key === key ? failed.message : null;

  return (
    <section
      ref={windowRef}
      tabIndex={-1}
      className="track-info"
      aria-label={t('tracks.info_title')}
      data-testid="track-info"
    >
      <header className="edit-route__head">
        <span className="edit-route__title">{t('tracks.info_title')}</span>
      </header>
      {info === null && error === null && <p className="confirm-dialog__message">{t('common.loading')}</p>}
      {error !== null && <p className="settings-page__error">{t('tracks.info_failed', { message: error })}</p>}
      {info !== null && (
        <dl className="track-info__lines">
          {info.lines.map((line) => (
            <div key={line.label} className="track-info__line">
              <dt>{line.label}</dt>
              <dd>{line.value}</dd>
            </div>
          ))}
        </dl>
      )}
      {info !== null && bandColors !== null && (
        <div className="track-info__bands" role="img" aria-label={t('tracks.info_bands')}>
          <span>{t('tracks.info_slower')}</span>
          <span className="track-info__band-steps" aria-hidden="true">
            {bandColors.map((color) => (
              <span key={color} style={{ background: color }} />
            ))}
          </span>
          <span>{t('tracks.info_faster')}</span>
        </div>
      )}
      {info !== null && info.note !== '' && <p className="track-info__note">{info.note}</p>}
      <div className="settings-page__save-row">
        <button type="button" className="settings-page__button" onClick={onClose}>
          {t('common.close')}
        </button>
      </div>
    </section>
  );
}
