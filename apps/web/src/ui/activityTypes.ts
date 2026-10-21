/**
 * What the page shows for each activity type, as the server says (`docs/SPEC.md` FR-5.1): every
 * activity list carries a `types` map and every Story its types' labels, in the page's language.
 * Android: `panel/ActivityTypes.kt`.
 */
const labels = new Map<string, string>();

/** What a response said about its types. */
export function rememberTypeLabels(described: Iterable<[string, string]>): void {
  for (const [type, label] of described) labels.set(type, label);
}

/** A type's label: the server's, else, for one no response has carried yet, the type spaced out
 *  from snake_case and title-cased, as the server falls back. */
export function typeLabel(activityType: string): string {
  return (
    labels.get(activityType) ??
    activityType
      .split('_')
      .filter(Boolean)
      .map((word) => word[0]!.toUpperCase() + word.slice(1))
      .join(' ')
  );
}
