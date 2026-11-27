/**
 * The Tracks panel's selection rules, as plain values so they're unit-tested apart from
 * `MapView.tsx`. Android keeps the same rules in `panel/PanelState.kt`.
 *
 * Focus and the checked group are independent: a row's text or its track focuses it (one at a
 * time); a checkbox builds the group the toolbar acts on.
 */
import type { Track } from '../api.ts';
import { passesFilters, type DistanceRange } from '../ui/trackFacets.ts';

/** `set` with `item` added, or removed if it was there. */
export function toggled<T>(set: ReadonlySet<T>, item: T): Set<T> {
  const next = new Set(set);
  if (next.has(item)) next.delete(item);
  else next.add(item);
  return next;
}

/** The tracks drawn bold: the checked group and the focused track, sorted. Android:
 *  `PanelRules.boldIds`. */
export function boldTracks(checked: ReadonlySet<string>, focused: string | null): string[] {
  const ids = new Set(checked);
  if (focused !== null) ids.add(focused);
  return [...ids].sort();
}

/** What the toolbar acts on: the checked group if anything is checked, else the focused row.
 *  Checked wins over a union so a Delete never reaches past what was ticked. */
export function toolbarTarget<S extends ReadonlySet<string>>(checked: S, focused: string | null): S | Set<string> {
  if (checked.size > 0) return checked;
  return new Set(focused !== null ? [focused] : []);
}

/** Whether Info shows the pace bands' legend: the map draws [focused]'s bands, and the
 *  toolbar's target is that track alone, checked or only focused. */
export function infoShowsBands(target: ReadonlySet<string>, focused: string | null, bandsDrawn: boolean): boolean {
  return bandsDrawn && focused !== null && target.size === 1 && target.has(focused);
}

/** What a tap on the master checkbox does, from how many of the [listed] rows are [checked]:
 *  with none, it checks every listed row; with some or all, it unchecks them all, so a partly
 *  checked box clears in one tap and All stays in its ▾ menu. */
export function masterCheckboxTap(listed: number, checked: number): 'checkAll' | 'uncheckAll' {
  return checked > 0 && listed > 0 ? 'uncheckAll' : 'checkAll';
}

/** How the panel's footer names the toolbar's target (FR-5.8's words): the Checked group, or the
 *  Focused row when nothing is checked, so a row that's only focused never reads as checked. */
export function targetSummaryKind(checkedCount: number, targetCount: number): 'checked' | 'focused' {
  return checkedCount === 0 && targetCount > 0 ? 'focused' : 'checked';
}

/** Show/Hide over the toolbar's target: if any of it is hidden, show all; otherwise hide all.
 *  One click never leaves the group mixed. */
export function toggledVisibility(hidden: ReadonlySet<string>, target: ReadonlySet<string>): Set<string> {
  const anyHidden = [...target].some((id) => hidden.has(id));
  const next = new Set(hidden);
  for (const id of target) {
    if (anyHidden) next.delete(id);
    else next.add(id);
  }
  return next;
}

/** `set` without `ids`; the same set when it holds none of them, so state doesn't change. */
export function withoutIds<T extends ReadonlySet<string>>(set: T, ids: ReadonlySet<string>): T | Set<string> {
  if (![...ids].some((id) => set.has(id))) return set;
  const next = new Set(set);
  for (const id of ids) next.delete(id);
  return next;
}

/** Inverts the check over the listed rows; a checked row the filters hide is dropped. */
export function invertedChecks(listed: readonly Pick<Track, 'id'>[], checked: ReadonlySet<string>): Set<string> {
  return new Set(listed.filter((a) => !checked.has(a.id)).map((a) => a.id));
}

/** Tracks the map doesn't draw or fly to: filtered out, hidden, or Pending (FR-5.8). Pending
 *  stays out of `hidden` so the user's own choice survives the reprocess. */
export function mapHiddenIds(
  tracks: readonly Track[],
  excludedTypes: ReadonlySet<string>,
  distanceFilter: DistanceRange | null,
  hidden: ReadonlySet<string>,
  pendingIds: readonly string[],
): Set<string> {
  const filteredOut = tracks.filter((a) => !passesFilters(a, excludedTypes, distanceFilter)).map((a) => a.id);
  return new Set([...filteredOut, ...hidden, ...pendingIds]);
}
