import type { Spot } from '../map/spots.ts';

/** What Copy address copies: OSM's address, or the coordinates when it has none — every
 *  navigator accepts "lat, lon". */
export function spotAddress(spot: Pick<Spot, 'address' | 'lat' | 'lon'>): string {
  return spot.address ?? `${spot.lat.toFixed(6)}, ${spot.lon.toFixed(6)}`;
}

/** The server's own test for a `wikipedia` tag it keeps (services/server/internal/spots/import.go's
 *  wikipediaTag), checked again here because the part before the colon becomes the link's host. */
const WIKIPEDIA_TAG = /^[a-z]{2,3}(-[a-z]+)?:[^:/][^/]*$/;

/** The article OSM's `wikipedia` tag names, "lang:Article title", on that language's Wikipedia;
 *  null for any other form, which would put something else in the link's host. */
export function wikipediaURL(tag: string): string | null {
  if (!WIKIPEDIA_TAG.test(tag)) return null;
  const colon = tag.indexOf(':');
  const title = tag.slice(colon + 1).trim().replace(/ /g, '_');
  return `https://${tag.slice(0, colon)}.wikipedia.org/wiki/${encodeURIComponent(title)}`;
}

/** OSM's `memorial` type as words: "war_memorial" → "War memorial". OSM's own English
 *  vocabulary, shown as it is in every language. */
export function memorialLabel(memorial: string): string {
  const words = memorial.replace(/[_;]+/g, ' ').trim();
  return words.charAt(0).toUpperCase() + words.slice(1);
}
