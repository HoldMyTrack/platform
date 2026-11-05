import { useEffect, useState } from 'react';
import { importsInFlight } from './firstRun';

/**
 * The header Upload menu's count of imports in flight (static/upload.js): read from its
 * `data-in-flight` attribute on mount, since the menu may have rendered first, then followed
 * through its `hmt:imports-in-flight` event. Zero where there is no menu, as in a demo.
 */
export function useImportsInFlight(): number {
  const [count, setCount] = useState(() => importsInFlight(document.querySelector('[data-upload-menu]')?.getAttribute('data-in-flight')));
  useEffect(() => {
    const onChange = (event: Event) => setCount(importsInFlight(String((event as CustomEvent<number>).detail)));
    window.addEventListener('hmt:imports-in-flight', onChange);
    return () => window.removeEventListener('hmt:imports-in-flight', onChange);
  }, []);
  return count;
}