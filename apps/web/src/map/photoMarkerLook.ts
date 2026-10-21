/**
 * How a photo marker looks, in CSS pixels: what index.css's `.photo-marker` rules draw on the live
 * map (through the custom properties `photoMarkerCssVars` names) and what exportPhotos.ts draws
 * into an exported image, so the two can't drift. Colors are the theme's tokens, read by both.
 * Android: `map/PhotoMarkers.kt`'s `PhotoMarkerLook`.
 */

export interface PhotoMarkerLookSize {
  /** The circle's diameter, and while its photo is open or in hand. */
  diameter: number;
  activeDiameter: number;
  /** The ring, and while open or in hand. */
  border: number;
  activeBorder: number;
  /** How far up and right each of a group's two cards behind it shows. */
  stack: number;
  /** A group's count: its pill's height, font size and side padding, and how far it overhangs
   *  the circle's box at the top and right. */
  countHeight: number;
  countFont: number;
  countPad: number;
  countTop: number;
  countRight: number;
}

/** Full size, and small: zoomed out (photoClusters.ts's photoMarkerSize). */
export const PHOTO_MARKER_LOOK: Record<'full' | 'small', PhotoMarkerLookSize> = {
  full: { diameter: 36, activeDiameter: 52, border: 2, activeBorder: 2, stack: 3, countHeight: 18, countFont: 11, countPad: 4, countTop: 8, countRight: 10 },
  small: { diameter: 22, activeDiameter: 36, border: 1.5, activeBorder: 2, stack: 2, countHeight: 14, countFont: 10, countPad: 3, countTop: 7, countRight: 9 },
};

/** The custom properties index.css reads, `--photo-marker-<size>-<field>`, in px. */
export function photoMarkerCssVars(): Record<string, string> {
  const vars: Record<string, string> = {};
  for (const [size, look] of Object.entries(PHOTO_MARKER_LOOK)) {
    for (const [field, value] of Object.entries(look)) {
      vars[`--photo-marker-${size}-${field.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`)}`] = `${value}px`;
    }
  }
  return vars;
}
