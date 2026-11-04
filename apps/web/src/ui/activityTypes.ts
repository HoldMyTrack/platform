import type { components } from '../apiSchema';

/**
 * What the page shows for each activity type, as the server says (`docs/SPEC.md` FR-5.1): every
 * activity list carries a `types` map of labels and kinds, and every Story its types' labels, in
 * the page's language. Android: `panel/ActivityTypes.kt`.
 */
const labels = new Map<string, string>();

/** The kind picks a row's icon (`activityKindIcon.ts`). */
export type ActivityKind = components['schemas']['ActivityTypes'][string]['kind'];

const kinds = new Map<string, ActivityKind>();

/** What a response said about its types. */
export function rememberTypeLabels(described: Iterable<[string, string]>): void {
  for (const [type, label] of described) labels.set(type, label);
}

export function rememberTypeKinds(described: Iterable<[string, ActivityKind]>): void {
  for (const [type, kind] of described) kinds.set(type, kind);
}

/** A type's kind: the server's, else `other` for one no activity list has carried yet. */
export function typeKind(activityType: string): ActivityKind {
  return kinds.get(activityType) ?? 'other';
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