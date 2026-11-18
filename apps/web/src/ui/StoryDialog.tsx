import { useState } from 'react';
import { createStory, updateStory, type Story } from '../api.ts';
import { STORY_MAX_DESCRIPTION_LEN, STORY_MAX_NAME_LEN } from '../limits.ts';
import { t } from '../i18n/index.ts';
import { ModalDialog, useDialogAction } from './ModalDialog.tsx';

/**
 * A Story's Name, required, and optional Description, in one of two uses:
 *
 *  - **Create** (`SPEC.md` FR-13.2) — the Activities panel toolbar's Create story, making a Story
 *    of the checked activities with one `POST /v1/stories` that carries them too.
 *  - **Edit** (FR-13.6) — a Stories tab folder's pencil, renaming it or changing its description.
 *
 * A ModalDialog that closes itself once the request has succeeded; `onSaved` gets the Story as the
 * server returned it, before `onClose` runs.
 *
 * A `<form>`, so Enter in the Name field saves; the Description is a textarea, where Enter is
 * a new line.
 */
type StoryDialogProps = (
  | {
      mode: 'create';
      activityIds: string[];
      /** What's being made into a Story — "3 checked activities (58 km)". */
      summary: string;
    }
  | { mode: 'edit'; story: Story }
) & {
  onSaved: (story: Story) => void;
  onClose: () => void;
};

export function StoryDialog(props: StoryDialogProps) {
  const { onSaved, onClose } = props;
  const [name, setName] = useState(props.mode === 'edit' ? props.story.name : '');
  const [description, setDescription] = useState(props.mode === 'edit' ? props.story.description : '');
  const { busy, error, run } = useDialogAction();

  async function save() {
    const input = { name: name.trim(), description: description.trim() };
    const story =
      props.mode === 'edit' ? await updateStory(props.story.id, input) : await createStory({ ...input, activityIds: props.activityIds });
    onSaved(story);
  }

  return (
    <ModalDialog
      title={props.mode === 'edit' ? t('stories.edit_title') : t('stories.create_title')}
      className="confirm-dialog story-dialog"
      testId="story-dialog"
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
          {props.mode === 'create' && <p className="confirm-dialog__message">{t('stories.create_body', { group: props.summary })}</p>}
          <label className="settings-page__section">
            <span className="settings-page__label">{t('stories.name')}</span>
            <input
              className="settings-page__input"
              type="text"
              value={name}
              onChange={(e) => setName(e.target.value)}
              maxLength={STORY_MAX_NAME_LEN}
              placeholder={t('stories.name_placeholder')}
              required
              autoFocus
              disabled={busy}
            />
          </label>
          <label className="settings-page__section">
            <span className="settings-page__label">{t('stories.description')}</span>
            <textarea
              className="settings-page__input edit-window__description"
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              maxLength={STORY_MAX_DESCRIPTION_LEN}
              placeholder={t('stories.description_placeholder')}
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
                  ? t('stories.creating')
                  : t('stories.create_confirm')}
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
