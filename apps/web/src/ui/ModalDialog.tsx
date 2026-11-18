import { useCallback, useEffect, useId, useRef, useState, type MouseEvent, type ReactNode } from 'react';
import { t } from '../i18n/index.ts';
import { onBackdrop } from './backdropPress.ts';

interface ModalDialogProps {
  title: ReactNode;
  className?: string;
  testId: string;
  /** While true, nothing closes the dialog, Escape and the backdrop included. */
  busy: boolean;
  onClose: () => void;
  /** Gets `close`, for a Cancel button or a dialog that closes itself once its request succeeds. */
  children: (close: () => void) => ReactNode;
}

/**
 * The shell ConfirmDialog, StoryDialog and SendCopyDialog share: a `<dialog>` opened with
 * `showModal()`, so Escape, the focus trap and the inert page come from the browser, named by its
 * title, with one way out (the dialog's own `close()`, which runs `onClose`) whether that came
 * from a button, Escape or the backdrop. Nothing closes it while `busy`, so a failure always has
 * somewhere to show.
 */
export function ModalDialog({ title, className = 'confirm-dialog', testId, busy, onClose, children }: ModalDialogProps) {
  const ref = useRef<HTMLDialogElement>(null);
  const titleId = useId();
  // A backdrop click is pressed and released outside the box: a drag that starts in a field and
  // ends outside is a text selection.
  const pressedOutside = useRef(false);
  const close = useCallback(() => ref.current?.close(), []);

  useEffect(() => {
    const el = ref.current;
    if (el && !el.open) el.showModal();
  }, []);

  const outside = (event: MouseEvent) => {
    const el = ref.current;
    return el !== null && onBackdrop(event.target === el, el.getBoundingClientRect(), event.clientX, event.clientY);
  };

  return (
    // The click is a mouse-only extra: Escape is the keyboard's way out, from the browser.
    // eslint-disable-next-line jsx-a11y/click-events-have-key-events, jsx-a11y/no-noninteractive-element-interactions
    <dialog
      ref={ref}
      className={className}
      data-testid={testId}
      aria-labelledby={titleId}
      onClose={onClose}
      onCancel={(event) => {
        if (busy) event.preventDefault();
      }}
      onPointerDown={(event) => {
        pressedOutside.current = outside(event);
      }}
      onClick={(event) => {
        if (pressedOutside.current && outside(event) && !busy) close();
        pressedOutside.current = false;
      }}
    >
      <h2 id={titleId} className="confirm-dialog__title">
        {title}
      </h2>
      {/* `close` reads the ref only when called, from a handler. */}
      {/* eslint-disable-next-line react-hooks/refs */}
      {children(close)}
    </dialog>
  );
}

/**
 * A dialog's one request: `run` marks it busy, clears the last error and, on a throw, shows the
 * error's message. It resolves true when the action succeeded, false when it failed or another
 * was still running.
 */
export function useDialogAction() {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  async function run(action: () => Promise<void>): Promise<boolean> {
    if (busy) return false;
    setBusy(true);
    setError(null);
    try {
      await action();
      return true;
    } catch (err) {
      setError(err instanceof Error ? err.message : t('common.something_wrong'));
      return false;
    } finally {
      setBusy(false);
    }
  }
  return { busy, error, run };
}
