import { useEffect, type RefObject } from 'react';

/**
 * Closes a dropdown or menu on a press outside `ref`'s element, or Escape, while `open`. `setOpen`
 * is a state setter, stable from render to render, so the listeners are bound once per opening.
 */
export function useDismiss(ref: RefObject<Element | null>, open: boolean, setOpen: (open: boolean) => void): void {
  useEffect(() => {
    if (!open) return;
    const onPointerDown = (event: PointerEvent) => {
      if (!ref.current?.contains(event.target as Node)) setOpen(false);
    };
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') setOpen(false);
    };
    document.addEventListener('pointerdown', onPointerDown);
    document.addEventListener('keydown', onKeyDown);
    return () => {
      document.removeEventListener('pointerdown', onPointerDown);
      document.removeEventListener('keydown', onKeyDown);
    };
  }, [ref, open, setOpen]);
}
