import { useCallback, useEffect, useMemo, useState } from 'react';
import { TrackNotFoundError, getTrack, type Track, type TrackDetail } from '../api.ts';
import { mapLimited } from '../limited.ts';
import { latestRows, missingRows, windowTracks } from './editWindowRows.ts';
import { editPhotosBlocker, editRouteBlocker } from '../ui/editAvailability.ts';
import type { EditTab } from '../ui/EditTrackWindow.tsx';
import type { MessageKey } from '../i18n/en.ts';

interface EditWindowState {
  /** The window's tracks, by id; null while it's closed. */
  ids: string[] | null;
  open: boolean;
  /** The Route tab's track (§4.7.7), until the window closes. Every other track is hidden and TrackEditor owns the map. */
  editingId: string | null;
  tab: EditTab;
  setTab: (tab: EditTab) => void;
  /** The window's tracks in full (`GET /v2/tracks/{id}`), with the newest list row seen
   *  for each over it; null while closed or while they load. */
  tracks: TrackDetail[] | null;
  routeBlocker: MessageKey | null;
  photosBlocker: MessageKey | null;
  openFor: (group: Track[]) => void;
  startRoute: (id: string) => void;
  /** Closes the window, returning the track whose track was being edited, if any. */
  close: () => string | null;
  /** Why the window closed on its own, until this is read: one of its tracks was deleted
   *  elsewhere, or they couldn't be read on opening (the server's message). */
  closedNotice: { deleted: true } | { failed: string } | null;
  dismissClosedNotice: () => void;
}

/** How many of the window's tracks are read at once: a group can be the 1,000 rows listed. */
const READS_AT_ONCE = 6;

/**
 * The Edit window over the toolbar's target. While it's open the panel is inert and the map's own
 * controls step aside. It reads its tracks in full on opening, since the list's rows are slim
 * (a group's type change still writes each one's own description), and shows once they land. It
 * closes when they can't be read or one was deleted, or the map would stay locked with no editor
 * to close it, and it opens on its Route tab.
 *
 * Trap: the tracks are the window's own once read. The list follows the map and Back
 * (FR-5.11), so a row leaving it says nothing about the track, and closing on that would drop
 * what is unsaved: one going missing from the list is read again, and only a `404` closes the
 * window, saying why, since what was unsaved for the whole group goes with it.
 */
export function useEditWindow(listed: readonly Track[]): EditWindowState {
  const [ids, setIds] = useState<string[] | null>(null);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [tab, setTab] = useState<EditTab>('track');
  const [closedNotice, setClosedNotice] = useState<EditWindowState['closedNotice']>(null);
  const open = ids !== null;

  const [details, setDetails] = useState<TrackDetail[] | null>(null);
  useEffect(() => {
    setDetails(null);
    if (ids === null) return;
    const controller = new AbortController();
    mapLimited(ids, READS_AT_ONCE, (id) => getTrack(id, controller.signal))
      .then(setDetails)
      .catch((error: unknown) => {
        if (controller.signal.aborted) return;
        setIds(null);
        setEditingId(null);
        setClosedNotice({ failed: error instanceof Error ? error.message : String(error) });
      });
    return () => controller.abort();
  }, [ids]);

  const [rows, setRows] = useState<ReadonlyMap<string, Track>>(new Map());
  useEffect(() => setRows(new Map()), [ids]);
  useEffect(() => {
    if (ids !== null) setRows((previous) => latestRows(previous, listed, ids));
  }, [ids, listed]);

  const tracks = useMemo(() => (ids === null || details === null ? null : windowTracks(details, rows)), [ids, details, rows]);

  // Keyed on which rows are missing, so each read happens once per row leaving the list.
  const missing = useMemo(() => (ids === null ? '' : missingRows(ids, listed).join(',')), [ids, listed]);
  useEffect(() => {
    if (missing === '') return;
    const controller = new AbortController();
    mapLimited(missing.split(','), READS_AT_ONCE, (id) => getTrack(id, controller.signal)).catch((error: unknown) => {
      // Any other failure says nothing about the track.
      if (controller.signal.aborted || !(error instanceof TrackNotFoundError)) return;
      setIds(null);
      setEditingId(null);
      setClosedNotice({ deleted: true });
    });
    return () => controller.abort();
  }, [missing]);

  useEffect(() => {
    setTab('track');
  }, [open]);

  const openFor = useCallback((group: Track[]) => setIds(group.map((a) => a.id)), []);
  const startRoute = useCallback((id: string) => setEditingId(id), []);
  const close = useCallback(() => {
    setIds(null);
    setEditingId(null);
    return editingId;
  }, [editingId]);

  return {
    ids,
    open,
    editingId,
    tab,
    setTab,
    tracks,
    routeBlocker: editRouteBlocker(tracks),
    photosBlocker: editPhotosBlocker(tracks),
    openFor,
    startRoute,
    close,
    closedNotice,
    dismissClosedNotice: useCallback(() => setClosedNotice(null), []),
  };
}
