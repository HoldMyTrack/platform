/** What "Show in this area" last loaded: the categories asked for, the category of each place it
 *  drew, and how many the area holds in all. */
export interface AreaLoad {
  categories: readonly string[];
  spotCategories: readonly string[];
  total: number;
}

/**
 * The count to say for the categories on now, or null when the last load can't say it and the
 * button has to come back: a category switched on since, or one switched off from a load cut at
 * the limit, whose total for the rest isn't known. The layer draws only the categories on, so a
 * load that wasn't cut counts what's left of it.
 */
export function areaCount(load: AreaLoad, categories: readonly string[]): { shown: number; total: number } | null {
  if (!categories.every((c) => load.categories.includes(c))) return null;
  if (load.categories.every((c) => categories.includes(c))) return { shown: load.spotCategories.length, total: load.total };
  if (load.spotCategories.length < load.total) return null;
  const shown = load.spotCategories.filter((c) => categories.includes(c)).length;
  return { shown, total: shown };
}
