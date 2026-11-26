/**
 * Folding the open Trip on the Trips tab: a click on its folder hides or shows its list of
 * tracks, with its description and statistics, and changes nothing else, so it stays open
 * (FR-13.6) with the map, URL and exports narrowed to it. A click on another folder opens that one unfolded.
 */
interface FolderClick {
  /** The Trip whose list is folded, or null when none is. */
  foldedId: string | null;
  /** Whether the clicked folder is another Trip, to open. */
  open: boolean;
}

export function folderClick(foldedId: string | null, openId: string | null, clickedId: string): FolderClick {
  if (clickedId !== openId) return { foldedId: null, open: true };
  return { foldedId: foldedId === clickedId ? null : clickedId, open: false };
}

/** Whether the open Trip's list is hidden; a fold left on another Trip counts for nothing. */
export function isFolded(foldedId: string | null, openId: string | null): boolean {
  return openId !== null && foldedId === openId;
}