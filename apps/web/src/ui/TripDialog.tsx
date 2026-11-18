import { useState } from 'react';
import { createTrip, updateTrip, type Trip } from '../api.ts';
import { TRIP_MAX_DESCRIPTION_LEN, TRIP_MAX_NAME_LEN } from '../limits.ts';
import { t } from '../i18n/index.ts';
import { ModalDialog, useDialogAction } from './ModalDialog.tsx';

/**
 * A Trip's Name, required, and optional Description, in one of two uses:
 *
 *  - **Create** (`SPEC.md` FR-13.2) — the Tracks panel toolbar's Create trip, making a Trip
 *    of the checked tracks with one `POST /v2/trips` that carries them too.
 *  - **Edit** (FR-13.6) — a Trips tab folder's pencil, renaming it or changing its description.
 *
 * A ModalDialog that closes itself once the request has succeeded; `onSaved` gets the Trip as the
 * server returned it, before `onClose` runs.
 *
 * A `<form>`, so Enter in the Name field saves; the Description is a textarea, where Enter is
 * a new line.
 */
type TripDialogProps = (
  | {
      mode: 'create';
      trackIds: string[];
      /** What's being made into a Trip — "3 checked tracks (58 km)". */
      summary: string;
    }
  | { mode: 'edit'; trip: Trip }
) & {
  onSaved: (trip: Trip) => void;
  onClose: () => void;
};

export function TripDialog(props: TripDialogProps) {
  const { onSaved, onClose } = props;
  const [name, setName] = useState(props.mode === 'edit' ? props.trip.name : '');
  const [description, setDescription] = useState(props.mode === 'edit' ? props.trip.description : '');
  const { busy, error, run } = useDialogAction();

  async function save() {
    const input = { name: name.trim(), description: description.trim() };
    const trip =
      props.mode === 'edit' ? await updateTrip(props.trip.id, input) : await createTrip({ ...input, trackIds: props.trackIds });
    onSaved(trip);
  }

  return (
    <ModalDialog
      title={props.mode === 'edit' ? t('trips.edit_title') : t('trips.create_title')}
      className="confirm-dialog trip-dialog"
      testId="trip-dialog"
      busy={busy}
      onClose={onClose}
    >
      {(close) => (
        <form
          onSubmit={async (event) => {
            event.preventDefault();
            if (name.trim() !== '' && (await run(save))) close();
          }}
        >
          {props.mode === 'create' && <p className="confirm-dialog__message">{t('trips.create_body', { group: props.summary })}</p>}
          <label className="settings-page__section">
            <span className="settings-page__label">{t('trips.name')}</span>
            <input
              className="settings-page__input"
              type="text"
              value={name}
              onChange={(e) => setName(e.target.value)}
              maxLength={TRIP_MAX_NAME_LEN}
              placeholder={t('trips.name_placeholder')}
              required
              autoFocus
              disabled={busy}
            />
          </label>
          <label className="settings-page__section">
            <span className="settings-page__label">{t('trips.description')}</span>
            <textarea
              className="settings-page__input edit-window__description"
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              maxLength={TRIP_MAX_DESCRIPTION_LEN}
              placeholder={t('trips.description_placeholder')}
              rows={3}
              disabled={busy}
            />
          </label>
          {error && <p className="settings-page__error">{error}</p>}
          <div className="settings-page__save-row">
            <button type="submit" className="settings-page__submit" disabled={busy || name.trim() === ''}>
              {props.mode === 'edit'
                ? busy
                  ? t('common.saving')
                  : t('common.save')
                : busy
                  ? t('trips.creating')
                  : t('trips.create_confirm')}
            </button>
            <button type="button" className="settings-page__button" disabled={busy} onClick={close}>
              {t('common.cancel')}
            </button>
          </div>
        </form>
      )}
    </ModalDialog>
  );
}
