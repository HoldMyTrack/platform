import type { MessageKey } from '../i18n/en';

/** What the Fog tooltip says about an outline (fogPlaces.ts). */

/** What an outline's tile feature carries (internal/httpapi's adminLayer.tileQuery). */
export interface PlaceProps {
  kind?: unknown;
  type?: unknown;
  name?: unknown;
  within?: unknown;
  visited?: unknown;
}

export interface PlaceLabel {
  name: string;
  kindKey: MessageKey;
  /** The places it lies in, nearest first, or '' for a country. */
  within: string;
  visitedKey: MessageKey;
}

/** What each kind of place is called where its own country has no word for it. */
const KIND_KEYS: Record<string, MessageKey> = {
  country: 'map.fog.place.country',
  region: 'map.fog.place.region',
  county: 'map.fog.place.county',
  city: 'map.fog.place.city',
};

/** The tooltip for an outline, or null for the sea or a feature it can't name. The kind is the
 *  place's own, as its country files it (Overture's local_type: state, prefecture, village), else
 *  the generic one. */
export function placeLabel(props: PlaceProps, has: (key: string) => key is MessageKey): PlaceLabel | null {
  const generic = typeof props.kind === 'string' ? KIND_KEYS[props.kind] : undefined;
  if (!generic || typeof props.name !== 'string' || props.name === '') return null;
  const own = typeof props.type === 'string' ? `map.fog.type.${props.type}` : '';
  // MapLibre hands a tile's boolean back as a boolean; a JSON round trip can make it a string.
  const visited = props.visited === true || props.visited === 'true';
  return {
    name: props.name,
    kindKey: has(own) ? own : generic,
    within: typeof props.within === 'string' ? props.within : '',
    visitedKey: visited ? 'map.fog.place.visited' : 'map.fog.place.unvisited',
  };
}
