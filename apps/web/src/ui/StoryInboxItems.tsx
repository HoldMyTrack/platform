import { useState } from 'react';
import { t, tn } from '../i18n';
import type { StoryInboxState } from './useStoryInbox';

/**
 * The Story copies others sent, each waiting to be accepted or declined, then the accepted ones
 * still arriving (docs/SPEC.md FR-14.7), as list items for the caller's `<ul>`: the Stories tab
 * and the first-run panel, where a copy can be an account's first activities.
 */
export function StoryInboxItems({ inbox }: { inbox: StoryInboxState }) {
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
        <li key={send.id} className="stories-tab__inbox" data-testid="stories-inbox">
          <p className="stories-tab__inbox-text">
            {t('stories.inbox_sent', { from: send.from, name: send.storyName })}
            <span className="stories-tab__inbox-count"> · {tn('activities.count', send.activityCount)}</span>
          </p>
          <div className="stories-tab__inbox-actions">
            <button
              type="button"
              className="settings-page__submit"
              disabled={answering !== null}
              onClick={() => void answer(send.id, true)}
            >
              {t('stories.inbox_accept')}
            </button>
            <button
              type="button"
              className="settings-page__button"
              disabled={answering !== null}
              onClick={() => void answer(send.id, false)}
            >
              {t('stories.inbox_decline')}
            </button>
          </div>
        </li>
      ))}
      {inbox.copying.map((copy, i) => (
        <li key={i} className="stories-tab__inbox stories-tab__inbox--copying" data-testid="stories-copying">
          <p className="stories-tab__inbox-text">{t('stories.inbox_copying', { from: copy.from, name: copy.storyName })}</p>
        </li>
      ))}
      {answerError && <li className="activities-panel__note activities-panel__note--error">{answerError}</li>}
    </>
  );
}