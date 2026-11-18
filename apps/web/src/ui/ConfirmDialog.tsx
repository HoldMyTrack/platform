import { useEffect, useId, useRef, useState, type MouseEvent, type RefObject } from 'react';
import { t } from '../i18n/index.ts';

/**
 * A generic "are you sure" confirm/cancel dialog — first used by the Activities panel's
 * Delete button (§4.7.5), but deliberately not delete-specific: any future destructive action
 * that needs a confirm step before committing can reuse this rather than growing its own.
 *
 * A real `<dialog>`/`showModal()` — free Escape/backdrop/focus-trap behavior, and exactly one path out (the dialog's own
 * `close()`) regardless of whether that came from Confirm, Cancel, Escape, or a backdrop
 * click. `onConfirm` is async and owned entirely here, the same self-contained shape
 * `EditActivityWindow.tsx`'s own Save button uses, rather than pushing busy/error
 * state onto whichever caller happens to render this — the dialog closes itself once
 * `onConfirm` actually resolves, not before. While it runs, nothing closes it — not Escape, not
 * the backdrop — so a failure always has somewhere to show. It opens on Cancel, so a held or
 * repeated Enter from the button that opened it can't confirm what may not be undone.
 */
export interface ConfirmDialogProps {
  title: string;
  message: string;
  /** Defaults to "Confirm"/"Cancel" — callers name the action explicitly ("Delete") when a
   *  generic label would read oddly for what's being confirmed. */
  confirmLabel?: string;
  /** null leaves only the confirm button, for a dialog that only informs. */
  cancelLabel?: string | null;
  busyLabel?: string;
  onConfirm: () => Promise<void>;
  onClose: () => void;
}

/**
 * Closes a modal `<dialog>` on a click on its backdrop: pressed and released outside the dialog's
 * box. The target alone doesn't tell them apart — the `<dialog>` is also the target of a click on
 * its own padding, and of a drag that starts in a field inside it and ends outside.
 */
export function useBackdropClose(ref: RefObject<HTMLDialogElement | null>, close: () => void) {
  const pressedOutside = useRef(false);
  const outside = (event: MouseEvent) => {
    const el = ref.current;
    if (!el || event.target !== el) return false;
    const box = el.getBoundingClientRect();
    return event.clientX < box.left || event.clientX > box.right || event.clientY < box.top || event.clientY > box.bottom;
  };
  return {
    onPointerDown: (event: MouseEvent) => {
      pressedOutside.current = outside(event);
    },
    onClick: (event: MouseEvent) => {
      if (pressedOutside.current && outside(event)) close();
      pressedOutside.current = false;
    },
  };
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
  const ref = useRef<HTMLDialogElement>(null);
  const cancelRef = useRef<HTMLButtonElement>(null);
  const titleId = useId();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const backdrop = useBackdropClose(ref, () => {
    if (!busy) ref.current?.close();
  });

  useEffect(() => {
    const el = ref.current;
    if (el && !el.open) el.showModal();
    cancelRef.current?.focus();
  }, []);

  async function handleConfirm() {
    setBusy(true);
    setError(null);
    try {
      await onConfirm();
      ref.current?.close();
    } catch (err) {
      setError(err instanceof Error ? err.message : t('common.something_wrong'));
    } finally {
      setBusy(false);
    }
  }

  return (
    <dialog
      ref={ref}
      className="confirm-dialog"
      data-testid="confirm-dialog"
      aria-labelledby={titleId}
      onClose={onClose}
      onCancel={(event) => {
        if (busy) event.preventDefault();
      }}
      {...backdrop}
    >
      <h2 id={titleId} className="confirm-dialog__title">{title}</h2>
      <p className="confirm-dialog__message">{message}</p>
      {error && <p className="settings-page__error">{error}</p>}
      <div className="settings-page__save-row">
        <button type="button" className="confirm-dialog__confirm" disabled={busy} onClick={() => void handleConfirm()}>
          {busy ? busyLabel : confirmLabel}
        </button>
        {cancelLabel !== null && (
          <button ref={cancelRef} type="button" className="settings-page__button" disabled={busy} onClick={() => ref.current?.close()}>
            {cancelLabel}
          </button>
        )}
      </div>
    </dialog>
  );
}
