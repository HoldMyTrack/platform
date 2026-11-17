import { useCallback, useEffect, useMemo, useState } from 'react';
import { ActivityNotFoundError, getActivity, type Activity, type ActivityDetail } from '../api';
import { latestRows, missingRows, windowActivities } from './editWindowRows';
import { editPhotosBlocker, editTrackBlocker } from '../ui/editAvailability';
import type { EditTab } from '../ui/EditActivityWindow';
import type { MessageKey } from '../i18n/en';

export interface EditWindowState {
  /** The window's activities, by id; null while it's closed. */
  ids: string[] | null;
  open: boolean;
  /** The Track tab's activity (§4.7.7), until the window closes. Every other track is hidden and TrackEditor owns the map. */
  editingId: string | null;
  tab: EditTab;
  setTab: (tab: EditTab) => void;
  /** The window's activities in full (`GET /v1/activities/{id}`), with the newest list row seen
   *  for each over it; null while closed or while they load. */
  activities: ActivityDetail[] | null;
  trackBlocker: MessageKey | null;
  photosBlocker: MessageKey | null;
  openFor: (group: Activity[]) => void;
  startTrack: (id: string) => void;
  /** Closes the window, returning the activity whose track was being edited, if any. */
  close: () => string | null;
  /** The window closed because one of its activities was deleted elsewhere, until this is read. */
  closedDeleted: boolean;
  dismissClosedDeleted: () => void;
}

/**
 * The Edit window over the toolbar's target. While it's open the panel is inert and the map's own
 * controls step aside. It reads its activities in full on opening, since the list's rows are slim
 * (a group's type change still writes each one's own description), and shows once they land. It
 * closes when they can't be read or one was deleted, or the map would stay locked with no editor
 * to close it, and it opens on its Activity tab.
 *
 * Trap: the activities are the window's own once read. The list follows the map and Back
 * (FR-5.11), so a row leaving it says nothing about the activity, and closing on that would drop
 * what is unsaved: one going missing from the list is read again, and only a `404` closes the
 * window, saying why, since what was unsaved for the whole group goes with it.
 */
export function useEditWindow(listed: readonly Activity[]): EditWindowState {
  const [ids, setIds] = useState<string[] | null>(null);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [tab, setTab] = useState<EditTab>('activity');
  const [closedDeleted, setClosedDeleted] = useState(false);
  const open = ids !== null;

  const [details, setDetails] = useState<ActivityDetail[] | null>(null);
  useEffect(() => {
    setDetails(null);
    if (ids === null) return;
    const controller = new AbortController();
    Promise.all(ids.map((id) => getActivity(id, controller.signal)))
      .then(setDetails)
      .catch(() => {
        if (controller.signal.aborted) return;
        setIds(null);
        setEditingId(null);
      });
    return () => controller.abort();
  }, [ids]);

  const [rows, setRows] = useState<ReadonlyMap<string, Activity>>(new Map());
  useEffect(() => setRows(new Map()), [ids]);
  useEffect(() => {
    if (ids !== null) setRows((previous) => latestRows(previous, listed, ids));
  }, [ids, listed]);

  const activities = useMemo(() => (ids === null || details === null ? null : windowActivities(details, rows)), [ids, details, rows]);

  // Keyed on which rows are missing, so each read happens once per row leaving the list.
  const missing = useMemo(() => (ids === null ? '' : missingRows(ids, listed).join(',')), [ids, listed]);
  useEffect(() => {
    if (missing === '') return;
    const controller = new AbortController();
    Promise.all(missing.split(',').map((id) => getActivity(id, controller.signal))).catch((error: unknown) => {
      // Any other failure says nothing about the activity.
      if (controller.signal.aborted || !(error instanceof ActivityNotFoundError)) return;
      setIds(null);
      setEditingId(null);
      setClosedDeleted(true);
    });
    return () => controller.abort();
  }, [missing]);

  useEffect(() => {
    setTab('activity');
  }, [open]);

  const openFor = useCallback((group: Activity[]) => setIds(group.map((a) => a.id)), []);
  const startTrack = useCallback((id: string) => setEditingId(id), []);
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
    activities,
    trackBlocker: editTrackBlocker(activities),
    photosBlocker: editPhotosBlocker(activities),
    openFor,
    startTrack,
    close,
    closedDeleted,
    dismissClosedDeleted: useCallback(() => setClosedDeleted(false), []),
  };
}
