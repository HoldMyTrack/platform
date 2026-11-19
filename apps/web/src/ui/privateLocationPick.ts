/**
 * What picking a Private location does, given the editor's state. A row click or a click on the
 * circle focuses it (highlighted, nothing editable); the row's pencil edits it. Either one leaving
 * an editor with unsaved changes asks first.
 */
export type PickIntent = 'focus' | 'edit';

/** `apply` does the intent; `keep` leaves the open editor as it is (the target is already in it). */
type PickAction = 'ignore' | 'keep' | 'confirm' | 'apply';

interface EditorState {
  open: boolean;
  /** The location in the editor; absent for a new one not saved yet. */
  id?: string | undefined;
  dirty: boolean;
  busy: boolean;
}

export function pickAction(editor: EditorState, targetId: string): PickAction {
  // A Save in flight closes the editor on success; picking now would race it.
  if (editor.busy) return 'ignore';
  if (!editor.open) return 'apply';
  if (editor.id === targetId) return 'keep';
  return editor.dirty ? 'confirm' : 'apply';
}

/** The circle drawn highlighted: the one in the editor, else the focused saved one. */
export function highlightedCircle<T extends { id?: string }>(locations: readonly T[] | null, draft: T | null, focusedId: string | null): T | null {
  if (draft) return draft;
  if (focusedId === null) return null;
  return locations?.find((l) => l.id === focusedId) ?? null;
}
/** The saved circles in the order they're drawn, each over the one before: oldest first, so the
 *  newest is on top. `selected` is left out, drawn last from the draft. `locations` come newest
 *  first, as the API lists them. */
export function drawOrder<T extends { id?: string }>(locations: readonly T[], selected: { id?: string } | null): T[] {
  return locations.filter((l) => !(selected && l.id !== undefined && l.id === selected.id)).reverse();
}

/** The location the Privacy tab opens on: the one added last, at the top, as the Trips tab
 *  opens on the newest Trip, so the map shows a circle rather than whatever was in view.
 *  `locations` come newest first, as the API lists them. */
export function openingLocation<T>(locations: readonly T[]): T | null {
  return locations[0] ?? null;
}
