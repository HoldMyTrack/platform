import { useEffect, type RefObject } from 'react';

/**
 * A floating window takes focus when it opens, and gives it back where it was when it closes:
 * the Edit window, the Private location editor and the export viewfinder sit over the map
 * rather than in a modal <dialog>, which would do this itself. The element gets tabIndex -1, so
 * focus lands on the window, and the next Tab on its first control.
 */
export function useWindowFocus(ref: RefObject<HTMLElement | null>): void {
  useEffect(() => {
    const before = document.activeElement;
    ref.current?.focus();
    return () => {
      // Back where it was, unless focus has moved somewhere of its own since.
      const now = document.activeElement;
      const lost = now === null || now === document.body || !now.isConnected;
      if (lost && before instanceof HTMLElement && before.isConnected) before.focus();
    };
  }, [ref]);
}
