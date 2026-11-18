import { useRef } from 'react';
import { t } from '../i18n/index.ts';
import { ModalDialog, useDialogAction } from './ModalDialog.tsx';

/**
 * A generic "are you sure" confirm/cancel dialog, for any action that needs a confirm step before
 * committing; first used by the Activities panel's Delete (§4.7.5). A ModalDialog that owns
 * `onConfirm`'s busy and error state, as `EditActivityWindow.tsx`'s Save does, and closes once
 * `onConfirm` resolves. It opens on Cancel, so a held or repeated Enter from the button that
 * opened it can't confirm what may not be undone.
 */
interface ConfirmDialogProps {
  title: string;
  message: string;
  /** Defaults to "Confirm"/"Cancel"; callers name the action ("Delete") where a generic label
   *  would read oddly. */
  confirmLabel?: string;
  /** null leaves only the confirm button, for a dialog that only informs. */
  cancelLabel?: string | null;
  busyLabel?: string;
  onConfirm: () => Promise<void>;
  onClose: () => void;
}

export function ConfirmDialog({
  title,
  message,
  confirmLabel = t('common.confirm'),
  cancelLabel = t('common.cancel'),
  busyLabel = t('common.working'),
  onConfirm,
  onClose,
}: ConfirmDialogProps) {
  const cancelRef = useRef<HTMLButtonElement>(null);
  const { busy, error, run } = useDialogAction();

  return (
    <ModalDialog title={title} testId="confirm-dialog" busy={busy} onClose={onClose} initialFocus={cancelRef}>
      {(close) => (
        <>
          <p className="confirm-dialog__message">{message}</p>
          {error && <p className="settings-page__error">{error}</p>}
          <div className="settings-page__save-row">
            <button
              type="button"
              className="confirm-dialog__confirm"
              disabled={busy}
              onClick={async () => {
                if (await run(onConfirm)) close();
              }}
            >
              {busy ? busyLabel : confirmLabel}
            </button>
            {cancelLabel !== null && (
              <button ref={cancelRef} type="button" className="settings-page__button" disabled={busy} onClick={close}>
                {cancelLabel}
              </button>
            )}
          </div>
        </>
      )}
    </ModalDialog>
  );
}
