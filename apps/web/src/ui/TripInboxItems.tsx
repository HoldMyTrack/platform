import { useState } from 'react';
import { t, tn } from '../i18n/index.ts';
import type { TripInboxState } from './useTripInbox.ts';

/**
 * The Trip copies others sent, each waiting to be accepted or declined, then the accepted ones
 * still arriving (docs/SPEC.md FR-13.7), as list items for the caller's `<ul>`: the Trips tab
 * and the first-run panel, where a copy can be an account's first tracks.
 */
export function TripInboxItems({ inbox }: { inbox: TripInboxState }) {
  // The waiting copy being answered, and why the last answer failed.
  const [answering, setAnswering] = useState<string | null>(null);
  const [answerError, setAnswerError] = useState<string | null>(null);

  async function answer(id: string, accept: boolean) {
    if (answering !== null) return;
    setAnswering(id);
    setAnswerError(null);
    try {
      await inbox.answer(id, accept);
    } catch (err) {
      setAnswerError(err instanceof Error ? err.message : t('common.something_wrong'));
    } finally {
      setAnswering(null);
    }
  }

  return (
    <>
      {inbox.sends.map((send) => (
        <li key={send.id} className="trips-tab__inbox" data-testid="trips-inbox">
          <p className="trips-tab__inbox-text">
            {t('trips.inbox_sent', { from: send.from, name: send.tripName })}
            <span className="trips-tab__inbox-count"> · {tn('tracks.count', send.trackCount)}</span>
          </p>
          <div className="trips-tab__inbox-actions">
            <button
              type="button"
              className="settings-page__submit"
              disabled={answering !== null}
              onClick={() => void answer(send.id, true)}
            >
              {t('trips.inbox_accept')}
            </button>
            <button
              type="button"
              className="settings-page__button"
              disabled={answering !== null}
              onClick={() => void answer(send.id, false)}
            >
              {t('trips.inbox_decline')}
            </button>
          </div>
        </li>
      ))}
      {inbox.copying.map((copy, i) => (
        <li key={i} className="trips-tab__inbox trips-tab__inbox--copying" data-testid="trips-copying">
          <p className="trips-tab__inbox-text">{t('trips.inbox_copying', { from: copy.from, name: copy.tripName })}</p>
        </li>
      ))}
      {answerError && <li className="tracks-panel__note tracks-panel__note--error">{answerError}</li>}
    </>
  );
}