/**
 * The web's Dates filter (docs/SPEC.md FR-5.20), as plain values: From (`after`) and To
 * (`before`), local YYYY-MM-DD dates, both inclusive and either empty; both empty is all time.
 */
export interface DateFilter {
  after: string | null;
  before: string | null;
}

export const ALL_TIME: DateFilter = { after: null, before: null };

/** What the filter's button says, before wording: all time, both ends, or one. */
export type DateFilterLabel =
  | { kind: 'all' }
  | { kind: 'between'; after: string; before: string }
  | { kind: 'after'; after: string }
  | { kind: 'before'; before: string };

export function dateFilterLabel({ after, before }: DateFilter): DateFilterLabel {
  if (after !== null && before !== null) return { kind: 'between', after, before };
  if (after !== null) return { kind: 'after', after };
  if (before !== null) return { kind: 'before', before };
  return { kind: 'all' };
}

/** What the pickers allow: the first activity's day (today without one) to today, the account's,
 *  or the newest activity's day when that's later: one recorded in a zone ahead can be dated
 *  tomorrow. */
export function dateFilterBounds(earliest: string | null, latest: string | null, today: string): { min: string; max: string } {
  return { min: earliest !== null && earliest < today ? earliest : today, max: latest !== null && latest > today ? latest : today };
}

/**
 * The filter once one end is set to `value`, or cleared with null: clamped into `bounds`, and the
 * other end moved to meet it if they crossed. `fly` asks for the camera to move onto what it
 * matches once (FR-5.20): only setting a date does, never clearing one, nor a value that changed
 * nothing.
 */
export function setDateFilter(
  current: DateFilter,
  end: 'after' | 'before',
  value: string | null,
  bounds: { min: string; max: string },
): { filter: DateFilter; fly: boolean } {
  let filter: DateFilter;
  if (value === null || value === '') {
    filter = { ...current, [end]: null };
  } else {
    const date = value < bounds.min ? bounds.min : value > bounds.max ? bounds.max : value;
    filter = { ...current, [end]: date };
    if (filter.after !== null && filter.before !== null && filter.after > filter.before) {
      filter = { after: date, before: date };
    }
  }
  const changed = filter.after !== current.after || filter.before !== current.before;
  return { filter, fly: changed && value !== null && value !== '' };
}