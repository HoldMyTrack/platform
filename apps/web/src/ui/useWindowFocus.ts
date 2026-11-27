import { useEffect, type RefObject } from 'react';

/**
 * Gives focus back, when the component leaves, to where it was when it came, unless focus has
 * moved somewhere of its own since: the floating windows below and the tour (Tour.tsx) share it.
 */
export function useRestoreFocus(): void {
  useEffect(() => {
    const before = document.activeElement;
    return () => {
      const now = document.activeElement;
      const lost = now === null || now === document.body || !now.isConnected;
      if (lost && before instanceof HTMLElement && before.isConnected) before.focus({ preventScroll: true });
    };
  }, []);
}

/**
 * A floating window takes focus when it opens, and gives it back where it was when it closes:
 * the Edit window, Info, the Private location editor and the export viewfinder sit over the map
 * rather than in a modal <dialog>, which would do this itself. The element gets tabIndex -1, so
 * focus lands on the window, and the next Tab on its first control; it's focused without
 * scrolling, and drawn without a ring (index.css), since the window itself isn't a control.
 */
export function useWindowFocus(ref: RefObject<HTMLElement | null>): void {
  useRestoreFocus();
  useEffect(() => {
    ref.current?.focus({ preventScroll: true });
  }, [ref]);
}
