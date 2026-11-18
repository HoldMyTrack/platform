import { useCallback, useEffect, useState } from 'react';
import { listPhotos, type Photo } from '../api.ts';

/** Whose photos to show: one track's, a Trip's, or none. */
export type PhotoScope = { track: string } | { trip: string } | null;

export interface PhotosState {
  photos: readonly Photo[];
  error: string | null;
  reload: () => void;
}

function scopeKey(scope: PhotoScope): string | null {
  if (scope === null) return null;
  return 'track' in scope ? `track:${scope.track}` : `trip:${scope.trip}`;
}

/**
 * The photos (FR-15) of the focused track or the open Trip — `GET /v1/photos`, refetched
 * whenever the scope or `version` changes or `reload` is called (after the Edit window saved). `version` is
 * whatever else should refetch them: MapView's `routeMetricsVersion`, bumped when a route edit
 * or a Private location change has been reprocessed — either can move a photo, or take it off
 * the map — and an open Trip's members. A new scope starts empty
 * rather than showing the last one's photos while it loads.
 */
export function usePhotos(scope: PhotoScope, version: number | string = 0): PhotosState {
  const key = scopeKey(scope);
  const [photos, setPhotos] = useState<readonly Photo[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [loadedKey, setLoadedKey] = useState<string | null>(null);
  const [nonce, setNonce] = useState(0);

  useEffect(() => {
    setError(null);
    if (key === null) {
      setPhotos([]);
      setLoadedKey(null);
      return;
    }
    const [kind, id] = key.split(':') as ['track' | 'trip', string];
    const controller = new AbortController();
    listPhotos(kind === 'track' ? { track: id } : { trip: id }, controller.signal)
      .then((list) => {
        setPhotos(list);
        setLoadedKey(key);
      })
      .catch((err: unknown) => {
        if (controller.signal.aborted) return;
        setPhotos([]);
        setError(err instanceof Error ? err.message : String(err));
      });
    return () => controller.abort();
  }, [key, nonce, version]);

  const reload = useCallback(() => setNonce((n) => n + 1), []);
  return { photos: loadedKey === key ? photos : [], error, reload };
}
