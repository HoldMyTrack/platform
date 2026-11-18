import { lazy, type ComponentType } from 'react';

/** sessionStorage key: when this tab last reloaded for a chunk it couldn't load. */
const RELOADED_AT_KEY = 'hmt.chunkReloadAt';

/** How long after one reload for a missing chunk another is refused, so a chunk that's missing
 *  for another reason (the network, a broken deploy) fails once instead of reloading forever. */
export const CHUNK_RELOAD_GAP_MS = 60_000;

/** Whether a failed chunk load should reload the page: not when it already did within the gap. */
export function reloadForChunk(lastReloadAt: number | null, now: number): boolean {
  return lastReloadAt === null || now - lastReloadAt > CHUNK_RELOAD_GAP_MS;
}

/**
 * React.lazy for a part of the app loaded on first use, whose chunk a deploy can take away from
 * a tab opened before it: content-hashed names change with every build. A load that fails then
 * reloads the page once, onto the new build, rather than leaving the error boundary's crash
 * screen; a second failure within the gap is thrown as before.
 */
export function lazyChunk<P extends object>(load: () => Promise<ComponentType<P>>) {
  return lazy(async () => {
    try {
      return { default: await load() };
    } catch (err) {
      let last: number | null = null;
      try {
        const saved = window.sessionStorage.getItem(RELOADED_AT_KEY);
        last = saved === null ? null : Number(saved);
      } catch {
        // No storage: reload anyway, once per page.
      }
      if (!reloadForChunk(last, Date.now())) throw err;
      try {
        window.sessionStorage.setItem(RELOADED_AT_KEY, String(Date.now()));
      } catch {
        // As above.
      }
      window.location.reload();
      return new Promise<never>(() => {});
    }
  });
}
