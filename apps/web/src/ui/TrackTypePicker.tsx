import { useCallback, useMemo } from 'react';
import type { TypeFacet } from './trackFacets.ts';
import { formatTrackType } from './format.ts';
import { fold, SearchPicker, type PickerOption } from './SearchPicker.tsx';
import { t } from '../i18n/index.ts';

interface TrackTypePickerProps {
  /** The raw `activity_type` value, e.g. "dog_walk" or "Solowheel". */
  value: string;
  onChange: (type: string) => void;
  /** Every type already in this account's loaded tracks, with how many use it — the
   *  same facets the Tracks panel's Type dropdown is built from (trackFacets.ts). */
  known: TypeFacet[];
  labelledBy: string;
  maxLength: number;
  /** What the closed picker shows while `value` is `''` — a mixed group's "Mixed types". */
  emptyLabel?: string;
}

function typeOption(type: string, count?: number): PickerOption {
  return {
    value: type,
    label: formatTrackType(type) || type,
    detail: count === undefined ? '' : String(count),
    keywords: [fold(type)],
  };
}

/**
 * The Edit window's Type field (EditTrackWindow.tsx) — the same picker as Settings' Country and
 * Timezone (search-picker.js there), over this account's existing types (formatted, with how many tracks use each),
 * but open-ended: activity_type is free-form (§4.7), not a controlled vocabulary, so any
 * search text that doesn't exactly match an existing type offers itself as a last "Add …" row
 * and saves exactly as typed. A value that isn't among the loaded types (just added, or
 * carried by a track whose type no other loaded track shares) still appears in the
 * list, so the current choice is always there to see.
 */
export function TrackTypePicker({ value, onChange, known, labelledBy, maxLength, emptyLabel }: TrackTypePickerProps) {
  const options = useMemo(() => {
    const list = known.map((f) => typeOption(f.type, f.count));
    if (value && !known.some((f) => f.type === value)) list.unshift(typeOption(value));
    return list;
  }, [known, value]);

  const createOption = useCallback(
    (text: string): PickerOption | null =>
      text.length > maxLength ? null : { value: text, label: t('picker.add_type', { type: text }), detail: t('picker.new'), keywords: [] },
    [maxLength],
  );

  return (
    <SearchPicker
      options={options}
      value={value}
      onChange={onChange}
      labelledBy={labelledBy}
      searchLabel={t('picker.search_type')}
      noMatches={(query) => t('picker.no_type_matches', { query })}
      placeholder={t('picker.search_type')}
      {...(emptyLabel !== undefined && { emptyLabel })}
      createOption={createOption}
    />
  );
}
