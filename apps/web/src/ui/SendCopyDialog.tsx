import { useState } from 'react';
import { sendTrip, type Trip } from '../api.ts';
import { t } from '../i18n/index.ts';
import { ModalDialog, useDialogAction } from './ModalDialog.tsx';

/**
 * Send a copy (`SPEC.md` FR-13.7): a Trips tab folder's send button, asking for the email
 * address to send a copy of the Trip to. A ModalDialog. Once sent it says so and stays open on
 * that, with the same words whether or not the address has an account — the server answers the
 * same either way, so the person sending can't tell — until it's closed.
 */
export function SendCopyDialog({ trip, onClose }: { trip: Trip; onClose: () => void }) {
  const [email, setEmail] = useState('');
  const [sentTo, setSentTo] = useState<string | null>(null);
  const { busy, error, run } = useDialogAction();

  async function handleSubmit(event: React.FormEvent) {
    event.preventDefault();
    const address = email.trim();
    if (address === '') return;
    await run(async () => {
      await sendTrip(trip.id, address);
      setSentTo(address);
      setEmail('');
    });
  }

  return (
    <ModalDialog
      title={t('trips.send_title', { name: trip.name })}
      className="confirm-dialog trip-dialog"
      testId="send-copy-dialog"
      busy={busy}
      onClose={onClose}
    >
      {(close) => (
        <form onSubmit={(event) => void handleSubmit(event)}>
          <p className="confirm-dialog__message">{t('trips.send_body')}</p>
          <label className="settings-page__section">
            <span className="settings-page__label">{t('trips.send_email')}</span>
            <input
              className="settings-page__input"
              type="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder={t('trips.send_email_placeholder')}
              autoComplete="email"
              required
              autoFocus
              disabled={busy}
            />
          </label>
          {sentTo && (
            <p className="settings-page__success" role="status">
              {t('trips.send_done', { email: sentTo })}
            </p>
          )}
          {error && <p className="settings-page__error">{error}</p>}
          <div className="settings-page__save-row">
            <button type="submit" className="settings-page__submit" disabled={busy || email.trim() === ''}>
              {busy ? t('trips.sending') : t('trips.send_confirm')}
            </button>
            <button type="button" className="settings-page__button" disabled={busy} onClick={close}>
              {sentTo ? t('common.close') : t('common.cancel')}
            </button>
          </div>
        </form>
      )}
    </ModalDialog>
  );
}
