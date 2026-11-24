/**
 * What the Library page (`docs/SPEC.md` FR-17.1) decides, as plain values: its state read from
 * and written to the URL, so Back and a shared link reopen the same page; the API query that
 * state asks for; the sort a column's header sets; the pager; and why the list is empty.
 *
 * The URL keeps the Type filter as the types left out, as the panel holds it, and Distance in
 * meters, as the slider moves: `?sort=distance_desc&page=2&q=lake&exclude=bus,driving&dmin=5000`.
 */

export type SortKey = 'started' | 'distance' | 'moving' | 'added';

export interface LibraryState {
  sort: SortKey;
  desc: boolean;
  page: number;
  q: string;
  /** Types left out, as the panel's Type filter holds them. */
  exclude: string[];
  /** Meters; an end the URL leaves out is 0 or Infinity, sent as no bound. */
  distance: { min: number; max: number } | null;
  dates: { after: string | null; before: string | null };
  trip: string | null;
}

export const DEFAULT_STATE: LibraryState = {
  sort: 'started',
  desc: true,
  page: 1,
  q: '',
  exclude: [],
  distance: null,
  dates: { after: null, before: null },
  trip: null,
};

const SORT_KEYS: readonly SortKey[] = ['started', 'distance', 'moving', 'added'];
const DAY = /^\d{4}-\d{2}-\d{2}$/;

/** The state a URL's query asks for; anything malformed is left at its default. */
export function parseLibraryUrl(search: string): LibraryState {
  const p = new URLSearchParams(search);
  const state: LibraryState = {
    ...DEFAULT_STATE,
    dates: { ...DEFAULT_STATE.dates },
  };
  const [key, dir] = (p.get('sort') ?? '').split('_');
  if (SORT_KEYS.includes(key as SortKey) && (dir === 'asc' || dir === 'desc')) {
    state.sort = key as SortKey;
    state.desc = dir === 'desc';
  }
  const page = Number(p.get('page'));
  if (Number.isInteger(page) && page >= 1 && page <= 1_000_000) state.page = page;
  state.q = (p.get('q') ?? '').trim().slice(0, 200);
  state.exclude = (p.get('exclude') ?? '').split(',').filter((type) => type !== '');
  const dmin = meters(p.get('dmin'));
  const dmax = meters(p.get('dmax'));
  if (dmin !== null || dmax !== null) {
    const min = dmin ?? 0;
    const max = dmax ?? Infinity;
    state.distance = min <= max ? { min, max } : { min: max, max: min };
  }
  const after = p.get('from');
  const before = p.get('to');
  state.dates = {
    after: after !== null && DAY.test(after) ? after : null,
    before: before !== null && DAY.test(before) ? before : null,
  };
  state.trip = p.get('trip') || null;
  return state;
}

function meters(v: string | null): number | null {
  if (v === null || v === '') return null;
  const n = Number(v);
  return Number.isFinite(n) && n >= 0 && n <= 1e9 ? n : null;
}

/** The URL query for `state`, its defaults left out: "" for the page as it first opens. */
export function libraryUrl(state: LibraryState): string {
  const p = new URLSearchParams();
  if (state.sort !== DEFAULT_STATE.sort || state.desc !== DEFAULT_STATE.desc) p.set('sort', `${state.sort}_${state.desc ? 'desc' : 'asc'}`);
  if (state.page > 1) p.set('page', String(state.page));
  if (state.q) p.set('q', state.q);
  if (state.exclude.length) p.set('exclude', state.exclude.join(','));
  if (state.distance) {
    if (state.distance.min > 0) p.set('dmin', String(Math.round(state.distance.min)));
    if (Number.isFinite(state.distance.max)) p.set('dmax', String(Math.round(state.distance.max)));
  }
  if (state.dates.after) p.set('from', state.dates.after);
  if (state.dates.before) p.set('to', state.dates.before);
  if (state.trip) p.set('trip', state.trip);
  const qs = p.toString();
  return qs ? `?${qs}` : '';
}

/**
 * The state after a filter, the search or the sort changed: back on page 1, since the page the
 * reader was on means something else now. Changing only the page keeps the rest.
 */
export function withFilter(state: LibraryState, change: Partial<Omit<LibraryState, 'page'>>): LibraryState {
  return { ...state, ...change, page: 1 };
}

/** A column header's sort: its own, largest or newest first, or the other way once it is the sort. */
export function sortBy(state: LibraryState, key: SortKey): LibraryState {
  return withFilter(state, {
    sort: key,
    desc: state.sort === key ? !state.desc : true,
  });
}

/** A column header's aria-sort. */
export function ariaSort(state: LibraryState, key: SortKey): 'ascending' | 'descending' | 'none' {
  if (state.sort !== key) return 'none';
  return state.desc ? 'descending' : 'ascending';
}

/**
 * The query `GET /v2/tracks` takes for `state`, given every type the account has (the bounds'):
 * the Type filter sent as the types kept. Null when every type is left out, which matches no
 * track, so there is nothing to ask for.
 */
export function pageQuery(state: LibraryState, allTypes: readonly string[]) {
  let types: string[] | undefined;
  if (state.exclude.length > 0 && allTypes.length > 0) {
    types = allTypes.filter((type) => !state.exclude.includes(type));
    if (types.length === 0) return null;
  }
  return {
    page: state.page,
    sort: `${state.sort}_${state.desc ? 'desc' : 'asc'}`,
    ...(state.q && { q: state.q }),
    ...(types && { types }),
    ...(state.distance && state.distance.min > 0 && { minDistance: state.distance.min }),
    ...(state.distance && Number.isFinite(state.distance.max) && { maxDistance: state.distance.max }),
    ...(state.dates.after && { from: state.dates.after }),
    ...(state.dates.before && { to: state.dates.before }),
    ...(state.trip && { trip: state.trip }),
  };
}

/** The pager: the rows shown, 1-based, and whether there is a page before and after. Null when
 *  the page shows no row. */
export function pager(page: number, total: number, pageSize: number): { from: number; to: number; prev: boolean; next: boolean } | null {
  const from = (page - 1) * pageSize + 1;
  if (total === 0 || from > total) return null;
  const to = Math.min(page * pageSize, total);
  return { from, to, prev: page > 1, next: to < total };
}

export type EmptyReason = 'no_tracks' | 'past_last' | 'search' | 'search_and_filters' | 'filters';

/**
 * Why a page has no row: the account has no track; the page is past the last, whatever the
 * filters (a Delete can empty the last page); the search matches nothing, with or without other
 * filters to clear; or only the filters match nothing.
 */
export function emptyReason(state: LibraryState, total: number, anyTrack: boolean): EmptyReason {
  if (!anyTrack) return 'no_tracks';
  if (total > 0) return 'past_last';
  if (state.q) return anyFilter({ ...state, q: '' }) ? 'search_and_filters' : 'search';
  return 'filters';
}

/** Whether any filter or the search is on: the count then says how many match, not how many
 *  the account has. */
export function anyFilter(state: LibraryState): boolean {
  return (
    state.q !== '' || state.exclude.length > 0 || state.distance !== null || state.dates.after !== null || state.dates.before !== null || state.trip !== null
  );
}

/** Where a row leads: the map, on the track and its own local day (`/?track=&day=`, as the
 *  Sync page links). */
export function mapHref(trackId: string, day: string): string {
  return `/?${new URLSearchParams({ track: trackId, day }).toString()}`;
}

/** The first checked track Download can't take, in the rows' order, to name in the toolbar's
 *  tooltip; null when it can take them all. */
export function firstBlocked<T extends { id: string; blocked: string | null }>(
  rows: readonly T[],
  checked: ReadonlySet<string>,
): (T & { blocked: NonNullable<T['blocked']> }) | null {
  const row = rows.find((r) => checked.has(r.id) && r.blocked !== null);
  return (row as (T & { blocked: NonNullable<T['blocked']> }) | undefined) ?? null;
}

/** Checked after the rows changed: only the ids still listed, since Checked stays within a page. */
export function keepListed(checked: ReadonlySet<string>, rows: readonly { id: string }[]): Set<string> {
  return new Set(rows.filter((row) => checked.has(row.id)).map((row) => row.id));
}
