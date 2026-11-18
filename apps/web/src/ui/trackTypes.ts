import type { components } from '../apiSchema.ts';

/**
 * What the page shows for each track type, as the server says (`docs/SPEC.md` FR-5.1): every
 * track list carries a `types` map of labels and kinds, and every Trip its types' labels, in
 * the page's language. Android: `panel/TrackTypes.kt`.
 */
const labels = new Map<string, string>();

/** The kind picks a row's icon (`trackKindIcon.ts`). */
export type TrackKind = components['schemas']['TrackTypes'][string]['kind'];

const kinds = new Map<string, TrackKind>();

/** What a response said about its types. */
export function rememberTypeLabels(described: Iterable<[string, string]>): void {
  for (const [type, label] of described) labels.set(type, label);
}

export function rememberTypeKinds(described: Iterable<[string, TrackKind]>): void {
  for (const [type, kind] of described) kinds.set(type, kind);
}

/** A type's kind: the server's, else `other` for one no track list has carried yet. */
export function typeKind(trackType: string): TrackKind {
  return kinds.get(trackType) ?? 'other';
}

/** A type's label: the server's, else, for one no response has carried yet, the type spaced out
 *  from snake_case and title-cased, as the server falls back. */
export function typeLabel(trackType: string): string {
  return (
    labels.get(trackType) ??
    trackType
      .split('_')
      .filter(Boolean)
      .map((word) => word[0]!.toUpperCase() + word.slice(1))
      .join(' ')
  );
}