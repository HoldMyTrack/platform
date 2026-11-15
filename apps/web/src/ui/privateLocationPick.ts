/**
 * What picking a Private location does, given the editor's state. A row click or a click on the
 * circle focuses it (highlighted, nothing editable); the row's pencil edits it. Either one leaving
 * an editor with unsaved changes asks first.
 */
export type PickIntent = 'focus' | 'edit';

/** `apply` does the intent; `keep` leaves the open editor as it is (the target is already in it). */
export type PickAction = 'ignore' | 'keep' | 'confirm' | 'apply';

export interface EditorState {
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