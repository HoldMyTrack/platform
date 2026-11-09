import { useEffect, useRef, useState } from 'react';
import { ChevronDown, Eye, EyeOff, Focus, Pencil, Trash2 } from 'lucide-react';
import { deleteActivity, type Activity, type Story } from '../api';
import { rowLabel } from './ActivityRow';
import { AddToStoryMenu } from './AddToStoryMenu';
import { ConfirmDialog } from './ConfirmDialog';
import { formatTotalDistance } from './format';
import { useUnitSystem } from './units';
import { t, tn } from '../i18n';

export interface ActivitiesToolbarProps {
  readOnly: boolean;
  /** The listed rows, already narrowed by the filters. */
  activities: Activity[];
  checked: Set<string>;
  /** What the toolbar acts on: the checked group, else the focused row (selection.ts's toolbarTarget). */
  targetIds: Set<string>;
  hiddenIds: Set<string>;
  onClear: () => void;
  onSelectAll: () => void;
  onInvertSelection: () => void;
  onToggleGroupVisibility: () => void;
  onEdit: (activities: Activity[]) => void;
  onStoryCreated: (story: Story) => void;
  onStoryAdded: (story: Story) => void;
  onActivitiesDeleted: (ids: string[]) => void;
  onShowSelected: () => void;
}

/**
 * The header toolbar right above the row list (ActivitiesPanel.tsx says what it acts on): the
 * master checkbox and its ▾ menu (All, None, Invert), then Show/hide, Edit, Add to story and
 * Delete over the target, and, set off by a divider, Focus on map. Each tooltip names the target
 * ("3 checked activities", or the focused row's own label), so which one applies is never a guess.
 */
export function ActivitiesToolbar({
  readOnly,
  activities,
  checked,
  targetIds,
  hiddenIds,
  onClear,
  onSelectAll,
  onInvertSelection,
  onToggleGroupVisibility,
  onEdit,
  onStoryCreated,
  onStoryAdded,
  onActivitiesDeleted,
  onShowSelected,
}: ActivitiesToolbarProps) {
  // The ▾ menu, dismissed on outside click or Escape.
  const [selectMenuOpen, setSelectMenuOpen] = useState(false);
  const selectMenuRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!selectMenuOpen) return;
    const onPointerDown = (event: PointerEvent) => {
      if (!selectMenuRef.current?.contains(event.target as Node)) setSelectMenuOpen(false);
    };
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') setSelectMenuOpen(false);
    };
    document.addEventListener('pointerdown', onPointerDown);
    document.addEventListener('keydown', onKeyDown);
    return () => {
      document.removeEventListener('pointerdown', onPointerDown);
      document.removeEventListener('keydown', onKeyDown);
    };
  }, [selectMenuOpen]);

  // The toolbar's Delete is the only delete entry point, for one activity or many.
  const [deletingGroup, setDeletingGroup] = useState(false);

  const system = useUnitSystem();
  const checkedCount = activities.filter((a) => checked.has(a.id)).length;
  const targetActivities = activities.filter((a) => targetIds.has(a.id));
  const targetMeters = targetActivities.reduce((sum, a) => sum + (a.distanceMeters ?? 0), 0);
  // The tooltips' name for the target, keyed on `checked`: one checked activity is still
  // "1 checked activity". Null when none of the target is listed, which disables the toolbar.
  const firstTarget = targetActivities[0];
  const targetName =
    firstTarget === undefined
      ? null
      : checked.size > 0
        ? tn('activities.checked_count', targetActivities.length)
        : t('activities.target_one', { label: rowLabel(firstTarget) });
  const hasTarget = targetName !== null;

  // `indeterminate` is a DOM property with no JSX prop, hence the ref and effect.
  const selectAllRef = useRef<HTMLInputElement>(null);
  const allChecked = activities.length > 0 && checkedCount === activities.length;
  const someChecked = checkedCount > 0 && !allChecked;
  useEffect(() => {
    if (selectAllRef.current) selectAllRef.current.indeterminate = someChecked;
  }, [someChecked]);

  const groupSummary = t('activities.group_summary', {
    activities: targetName ?? '',
    distance: formatTotalDistance(targetMeters, system),
  });
  // Show all of the target once any of it is hidden (selection.ts's toggledVisibility).
  const groupHasHidden = targetActivities.some((a) => hiddenIds.has(a.id));
  // Pending rows can't be deleted until their reprocess lands, which would race the delete.
  const groupHasPending = targetActivities.some((a) => a.pending);

  const noTarget = t('activities.no_target');
  const visibilityTitle =
    targetName === null
      ? noTarget
      : t(groupHasHidden ? 'activities.show_target' : 'activities.hide_target', { target: targetName });
  const editTitle =
    targetName === null
      ? noTarget
      : t(targetActivities.length === 1 ? 'activities.edit_one' : 'activities.edit_many', { target: targetName });
  const deleteTitle = targetName === null ? noTarget : t('activities.delete_target', { target: targetName });
  const focusTitle = targetName === null ? noTarget : t('activities.focus_target', { target: targetName });

  return (
    <>
    {/* The header toolbar — right above the row list. There are no per-row action icons
        to stay column-aligned with (Visible/Edit/Delete all live here, operating on the
        toolbar's target), so this is a plain compact strip: select-all checkbox and its
        ▾ menu (All, None, Invert), a spacer, the action chips, a divider, then the one
        accent-tinted "focus the map on the target" action. */}
    <div className="activities-panel__toolbar">
      <input
        ref={selectAllRef}
        type="checkbox"
        className="activities-panel__checkbox"
        checked={allChecked}
        disabled={activities.length === 0}
        aria-label={allChecked ? t('activities.uncheck_all_label') : t('activities.check_all_label')}
        title={allChecked ? t('activities.uncheck_all') : t('activities.check_all')}
        onChange={() => (allChecked || someChecked ? onClear() : onSelectAll())}
      />
      <div className="select-menu" ref={selectMenuRef}>
        <button
          type="button"
          className="select-menu__trigger"
          data-testid="select-menu"
          disabled={activities.length === 0}
          aria-haspopup="menu"
          aria-expanded={selectMenuOpen}
          aria-label={t('activities.select_menu')}
          title={t('activities.select_menu')}
          onClick={() => setSelectMenuOpen((open) => !open)}
        >
          <ChevronDown size={12} />
        </button>
        {selectMenuOpen && (
          <div className="story-menu__panel select-menu__panel" role="menu" aria-label={t('activities.select_menu')}>
            {(
              [
                ['all', t('activities.select_all'), allChecked, onSelectAll],
                ['none', t('activities.select_none'), checkedCount === 0, onClear],
                ['invert', t('activities.select_invert'), false, onInvertSelection],
              ] as const
            ).map(([key, label, disabled, run]) => (
              <button
                key={key}
                type="button"
                role="menuitem"
                className="story-menu__item"
                data-testid={`select-${key}`}
                disabled={disabled}
                onClick={() => {
                  setSelectMenuOpen(false);
                  run();
                }}
              >
                <span className="story-menu__name">{label}</span>
              </button>
            ))}
          </div>
        )}
      </div>

      <span className="activities-panel__toolbar-spacer" aria-hidden="true" />

      <button
        type="button"
        className="activities-panel__visibility"
        disabled={!hasTarget}
        onClick={onToggleGroupVisibility}
        aria-label={visibilityTitle}
        title={visibilityTitle}
      >
        {groupHasHidden ? <EyeOff size={16} /> : <Eye size={16} />}
      </button>
      <button
        type="button"
        className="activities-panel__edit"
        disabled={readOnly || !hasTarget}
        onClick={() => onEdit(targetActivities)}
        aria-label={editTitle}
        title={readOnly ? t('activities.demo_edit_activities') : editTitle}
      >
        <Pencil size={16} />
      </button>
      <AddToStoryMenu
        readOnly={readOnly}
        target={targetActivities}
        targetName={targetName}
        summary={groupSummary}
        onCreated={onStoryCreated}
        onAdded={onStoryAdded}
      />
      <button
        type="button"
        className="activities-panel__delete"
        disabled={readOnly || !hasTarget || groupHasPending}
        onClick={() => setDeletingGroup(true)}
        aria-label={deleteTitle}
        title={readOnly ? t('activities.demo_delete') : deleteTitle}
      >
        <Trash2 size={16} />
      </button>
      <span className="activities-panel__toolbar-divider" aria-hidden="true" />
      <button
        type="button"
        className="activities-panel__focus"
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
        title={targetActivities.length === 1 ? t('activities.delete_one_title') : t('activities.delete_title')}
        message={
          targetActivities.length === 1
            ? t('activities.delete_one_body', { group: groupSummary })
            : t('activities.delete_many_body', { group: groupSummary })
        }
        confirmLabel={t('activities.delete_confirm')}
        busyLabel={t('common.deleting')}
        onConfirm={async () => {
          // Sequential, not Promise.all: N concurrent DELETEs against the same account's
          // fog_tiles rows would race each other's dirty-mark-and-render trigger for no
          // benefit — a checked group is a handful of rows a user selected by hand, not a
          // bulk-import scale operation, so there's no latency reason to parallelize this.
          const deleted: string[] = [];
          try {
            for (const activity of targetActivities) {
              await deleteActivity(activity.id);
              deleted.push(activity.id);
            }
          } finally {
            // The ones already gone leave the list and the group even when a later one fails,
            // so the dialog's retry deletes only the rest.
            if (deleted.length > 0) onActivitiesDeleted(deleted);
          }
        }}
        onClose={() => setDeletingGroup(false)}
      />
    )}
    </>
  );
}
