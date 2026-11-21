/** What SearchPicker's search reads of a row. */
export interface Searchable {
  value: string;
  label: string;
  /** Extra search terms beyond the label, already folded (see `fold`). */
  keywords?: string[];
  /** Terms that, typed exactly, float this option to the top — a country's ISO code. */
  exact?: string[];
}

/** Case- and accent-insensitive, so "aland" finds "Åland Islands" and "sao" finds "São Paulo":
 *  every nonspacing mark goes, as on Android and iOS (testdata/client-rules/type-search.json). */
export function fold(s: string): string {
  return s.toLowerCase().normalize('NFD').replace(/\p{Mn}/gu, '');
}

/** A string's length as the server counts it, in code points. */
export function codePoints(s: string): number {
  return [...s].length;
}

/** Ranks an exact match first — an exact term ("us" → United States, not Australia) or the
 *  whole label ("walk" → Walk, before Dog Walk) — then labels with a word starting with the
 *  query, then anything containing it; the caller's own order is kept within each rank. A row's
 *  detail (a type's count) is never searched. */
export function search<T extends Searchable>(options: T[], query: string): T[] {
  const q = fold(query.trim());
  const ranked: T[][] = [[], [], []];
  for (const o of options) {
    const label = fold(o.label);
    if (label === q || o.exact?.some((t) => fold(t) === q)) ranked[0]!.push(o);
    else if (label.startsWith(q) || label.includes(` ${q}`)) ranked[1]!.push(o);
    else if (label.includes(q) || o.keywords?.some((k) => k.includes(q))) ranked[2]!.push(o);
  }
  return ranked.flat();
}

/** The rows a search shows: the matches, then, while no option's value or label equals the
 *  trimmed query, the row `create` builds from it (null when it can't be a value). */
export function searchRows<T extends Searchable>(options: T[], query: string, create?: (text: string) => T | null): T[] {
  const text = query.trim();
  if (!text) return options;
  const matches = search(options, text);
  const q = fold(text);
  const exact = options.some((o) => fold(o.value) === q || fold(o.label) === q);
  const created = !exact && create ? create(text) : null;
  return created ? [...matches, created] : matches;
}

/** The Type picker's rows before any search (testdata/client-rules/type-options.json): known in
 *  its order, led by current with count 0 when none of them is it. An empty current, a mixed
 *  group's, adds nothing. */
export function typeOptions(current: string, known: { type: string; count: number }[]): { type: string; count: number }[] {
  return !current || known.some((k) => k.type === current) ? known : [{ type: current, count: 0 }, ...known];
}

/** The Type picker's search (testdata/client-rules/type-search.json): the values shown, and the
 *  text offered as a new type, if any. */
export function typeSearch(
  options: { value: string; label: string }[],
  query: string,
  maxLength: number,
): { shown: string[]; add: string | null } {
  const rows = options.map((o) => ({ ...o, keywords: [fold(o.value)], added: false }));
  const shown = searchRows(rows, query, (text) =>
    codePoints(text) > maxLength ? null : { value: text, label: text, keywords: [], added: true },
  );
  return { shown: shown.filter((r) => !r.added).map((r) => r.value), add: shown.find((r) => r.added)?.value ?? null };
}