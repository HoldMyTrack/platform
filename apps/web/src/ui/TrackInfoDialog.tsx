import { useEffect, useRef, useState } from 'react';
import { getTrackInfo, type TrackInfo } from '../api.ts';
import { t } from '../i18n/index.ts';
import { ModalDialog } from './ModalDialog.tsx';

interface TrackInfoDialogProps {
  /** The toolbar's target. */
  trackIds: readonly string[];
  /** The pace bands' colors, slowest first, while the map draws them for this one track; else null. */
  bandColors: readonly string[] | null;
  onClose: () => void;
}

/**
 * The toolbar's Info (docs/SPEC.md FR-5.8): the server's lines for the target (`POST /v2/tracks/info`),
 * the pace bands' legend while the map draws them, and the server's note under them.
 */
export function TrackInfoDialog({ trackIds, bandColors, onClose }: TrackInfoDialogProps) {
  const [info, setInfo] = useState<TrackInfo | null>(null);
  const [error, setError] = useState<string | null>(null);
  const closeRef = useRef<HTMLButtonElement>(null);
  const key = trackIds.join(',');

  useEffect(() => {
    const abort = new AbortController();
    getTrackInfo(key.split(','), abort.signal).then(setInfo, (err: unknown) => {
      if (!abort.signal.aborted) setError(err instanceof Error ? err.message : String(err));
    });
    return () => abort.abort();
  }, [key]);

  return (
    <ModalDialog title={t('tracks.info_title')} className="confirm-dialog track-info" testId="track-info" busy={false} onClose={onClose} initialFocus={closeRef}>
      {(close) => (
        <>
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
            <button ref={closeRef} type="button" className="settings-page__button" onClick={close}>
              {t('common.close')}
            </button>
          </div>
        </>
      )}
    </ModalDialog>
  );
}
