import { useState } from 'react';
import { Eye, EyeOff, Focus, Pencil, Trash2 } from 'lucide-react';
import { CheckAllMenu } from './CheckAllMenu.tsx';
import { deleteTrack, type Track, type Trip } from '../api.ts';
import { rowLabel } from './TrackRow.tsx';
import { AddToTripMenu } from './AddToTripMenu.tsx';
import { ConfirmDialog } from './ConfirmDialog.tsx';
import { formatTotalDistance } from './format.ts';
import { useUnitSystem } from './units.ts';
import { t, tn } from '../i18n/index.ts';

interface TracksToolbarProps {
  readOnly: boolean;
  /** The listed rows, already narrowed by the filters. */
  tracks: Track[];
  checked: Set<string>;
  /** What the toolbar acts on: the checked group, else the focused row (selection.ts's toolbarTarget). */
  targetIds: Set<string>;
  hiddenIds: Set<string>;
  onClear: () => void;
  onSelectAll: () => void;
  onInvertSelection: () => void;
  onToggleGroupVisibility: () => void;
  onEdit: (tracks: Track[]) => void;
  onTripCreated: (trip: Trip) => void;
  onTripAdded: (trip: Trip) => void;
  onTracksDeleted: (ids: string[]) => void;
  onShowSelected: () => void;
}

/**
 * The header toolbar right above the row list (TracksPanel.tsx says what it acts on): the
 * master checkbox and its ▾ menu (All, None, Invert), then Show/hide, Edit, Add to trip and
 * Delete over the target, and, set off by a divider, Focus on map. Each tooltip names the target
 * ("3 checked tracks", or the focused row's own label), so which one applies is never a guess.
 */
export function TracksToolbar({
  readOnly,
  tracks,
  checked,
  targetIds,
  hiddenIds,
  onClear,
  onSelectAll,
  onInvertSelection,
  onToggleGroupVisibility,
  onEdit,
  onTripCreated,
  onTripAdded,
  onTracksDeleted,
  onShowSelected,
}: TracksToolbarProps) {
  // The toolbar's Delete is the only delete entry point, for one track or many.
  const [deletingGroup, setDeletingGroup] = useState(false);

  const system = useUnitSystem();
  const checkedCount = tracks.filter((a) => checked.has(a.id)).length;
  const targetTracks = tracks.filter((a) => targetIds.has(a.id));
  const targetMeters = targetTracks.reduce((sum, a) => sum + (a.distanceMeters ?? 0), 0);
  // The tooltips' name for the target, keyed on `checked`: one checked track is still
  // "1 checked track". Null when none of the target is listed, which disables the toolbar.
  const firstTarget = targetTracks[0];
  const targetName =
    firstTarget === undefined
      ? null
      : checked.size > 0
        ? tn('tracks.checked_count', targetTracks.length)
        : t('tracks.target_one', { label: rowLabel(firstTarget) });
  const hasTarget = targetName !== null;

  const groupSummary = t('tracks.group_summary', {
    name: targetName ?? '',
    distance: formatTotalDistance(targetMeters, system),
  });
  // Show all of the target once any of it is hidden (selection.ts's toggledVisibility).
  const groupHasHidden = targetTracks.some((a) => hiddenIds.has(a.id));
  // Pending rows can't be deleted until their reprocess lands, which would race the delete.
  const groupHasPending = targetTracks.some((a) => a.pending);

  const noTarget = t('tracks.no_target');
  const visibilityTitle =
    targetName === null
      ? noTarget
      : t(groupHasHidden ? 'tracks.show_target' : 'tracks.hide_target', { target: targetName });
  const editTitle =
    targetName === null
      ? noTarget
      : t(targetTracks.length === 1 ? 'tracks.edit_one' : 'tracks.edit_many', { target: targetName });
  const deleteTitle = targetName === null ? noTarget : t('tracks.delete_target', { target: targetName });
  const focusTitle = targetName === null ? noTarget : t('tracks.focus_target', { target: targetName });

  return (
    <>
    {/* The header toolbar — right above the row list. There are no per-row action icons
        to stay column-aligned with (Visible/Edit/Delete all live here, operating on the
        toolbar's target), so this is a plain compact strip: select-all checkbox and its
        ▾ menu (All, None, Invert), a spacer, the action chips, a divider, then the one
        accent-tinted "focus the map on the target" action. */}
    <div className="tracks-panel__toolbar">
      <CheckAllMenu total={tracks.length} checkedCount={checkedCount} onAll={onSelectAll} onNone={onClear} onInvert={onInvertSelection} />

      <span className="tracks-panel__toolbar-spacer" aria-hidden="true" />

      <button
        type="button"
        className="tracks-panel__visibility"
        disabled={!hasTarget}
        onClick={onToggleGroupVisibility}
        aria-label={visibilityTitle}
        title={visibilityTitle}
      >
        {groupHasHidden ? <EyeOff size={16} /> : <Eye size={16} />}
      </button>
      <button
        type="button"
        className="tracks-panel__edit"
        disabled={readOnly || !hasTarget}
        onClick={() => onEdit(targetTracks)}
        aria-label={editTitle}
        title={readOnly ? t('tracks.demo_edit_tracks') : editTitle}
      >
        <Pencil size={16} />
      </button>
      <AddToTripMenu
        readOnly={readOnly}
        target={targetTracks}
        targetName={targetName}
        summary={groupSummary}
        onCreated={onTripCreated}
        onAdded={onTripAdded}
      />
      <button
        type="button"
        className="tracks-panel__delete"
        disabled={readOnly || !hasTarget || groupHasPending}
        onClick={() => setDeletingGroup(true)}
        aria-label={deleteTitle}
        title={readOnly ? t('tracks.demo_delete') : deleteTitle}
      >
        <Trash2 size={16} />
      </button>
      <span className="tracks-panel__toolbar-divider" aria-hidden="true" />
      <button
        type="button"
        className="tracks-panel__focus"
        disabled={!hasTarget}
        onClick={onShowSelected}
        aria-label={focusTitle}
        title={focusTitle}
      >
        <Focus size={16} />
      </button>
    </div>
    {deletingGroup && (
      <ConfirmDialog
        title={targetTracks.length === 1 ? t('tracks.delete_one_title') : t('tracks.delete_title')}
        message={
          targetTracks.length === 1
            ? t('tracks.delete_one_body', { group: groupSummary })
            : t('tracks.delete_many_body', { group: groupSummary })
        }
        confirmLabel={t('tracks.delete_confirm')}
        busyLabel={t('common.deleting')}
        onConfirm={async () => {
          // Sequential, not Promise.all: N concurrent DELETEs against the same account's
          // fog_tiles rows would race each other's dirty-mark-and-render trigger for no
          // benefit — a checked group is a handful of rows a user selected by hand, not a
          // bulk-import scale operation, so there's no latency reason to parallelize this.
          const deleted: string[] = [];
          try {
            for (const track of targetTracks) {
              await deleteTrack(track.id);
              deleted.push(track.id);
            }
          } finally {
            // The ones already gone leave the list and the group even when a later one fails,
            // so the dialog's retry deletes only the rest.
            if (deleted.length > 0) onTracksDeleted(deleted);
          }
        }}
        onClose={() => setDeletingGroup(false)}
      />
    )}
    </>
  );
}
