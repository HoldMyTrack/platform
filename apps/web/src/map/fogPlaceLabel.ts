import type { MessageKey } from '../i18n/en';

/** PROTOTYPE (FOG_REWORK.md "Borders and names"): what the Fog tooltip says about an outline
 *  (fogPlaces.ts). */

/** What an outline's tile feature carries (internal/httpapi's adminLayer.tileQuery). */
export interface PlaceProps {
  kind?: unknown;
  name?: unknown;
  visited?: unknown;
}

export interface PlaceLabel {
  name: string;
  kindKey: MessageKey;
  visitedKey: MessageKey;
}

const KIND_KEYS: Record<string, MessageKey> = {
  country: 'map.fog.place.country',
  region: 'map.fog.place.region',
  city: 'map.fog.place.city',
  county: 'map.fog.place.county',
};

/** The tooltip for an outline, or null for the sea or a feature it can't name. */
export function placeLabel(props: PlaceProps): PlaceLabel | null {
  const kindKey = typeof props.kind === 'string' ? KIND_KEYS[props.kind] : undefined;
  if (!kindKey || typeof props.name !== 'string' || props.name === '') return null;
  // MapLibre hands a tile's boolean back as a boolean; a JSON round trip can make it a string.
  const visited = props.visited === true || props.visited === 'true';
  return { name: props.name, kindKey, visitedKey: visited ? 'map.fog.place.visited' : 'map.fog.place.unvisited' };
}
