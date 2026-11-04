/**
 * The one-glyph font the direction chevrons are drawn in (bandsGroup.ts), as MapLibre's glyph range
 * format: a protobuf of signed distance fields. A glyph rather than an icon because only text
 * placed along a line honours `text-max-angle` and turns glyph by glyph with the line.
 */

export const CHEVRON_FONT = 'HoldMyTrack Chevron';
export const CHEVRON_RANGE = '57344-57599';
const CHEVRON_CODE_POINT = 0xe000;

/** MapLibre's em: at `text-size` S a glyph draws at S/24, so this height makes S the chevron's width. */
const HEIGHT = 24;
/** How far each arm runs along the line, band edge to tip. */
const ARM = 14.4;
/** The chevron's thickness along the line. */
const THICKNESS = 9.6;
const WIDTH = ARM + THICKNESS;
/** Back edge to back edge: what's left past THICKNESS is the gap between chevrons in a group. */
const ADVANCE = 16;
/** MapLibre sets a glyph's baseline 17 above the anchor, so this centers it on the line. */
const TOP = HEIGHT / 2 - 17;

const BUFFER = 3; // MapLibre's padding around a glyph's bitmap
const SDF_RADIUS = 8;
const SDF_CUTOFF = 0.25;

/** The chevron's outline in glyph pixels, y down, pointing along +x. */
export function chevronOutline() {
  return [[0, 0], [THICKNESS, 0], [WIDTH, HEIGHT / 2], [THICKNESS, HEIGHT], [0, HEIGHT], [ARM, HEIGHT / 2]];
}

function signedDistance(x, y, polygon) {
  let nearest = Infinity;
  let inside = false;
  for (let i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    const [ax, ay] = polygon[j];
    const [bx, by] = polygon[i];
    const dx = bx - ax;
    const dy = by - ay;
    const t = Math.max(0, Math.min(1, ((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy)));
    nearest = Math.min(nearest, Math.hypot(x - ax - t * dx, y - ay - t * dy));
    if (ay > y !== by > y && x < ax + ((y - ay) / dy) * dx) inside = !inside;
  }
  return inside ? -nearest : nearest;
}

/** The glyph's distance field, one byte per pixel with BUFFER around it; 191 marks the outline. */
export function chevronBitmap() {
  const polygon = chevronOutline();
  const columns = Math.ceil(WIDTH) + 2 * BUFFER;
  const rows = HEIGHT + 2 * BUFFER;
  const bitmap = new Uint8Array(columns * rows);
  for (let row = 0; row < rows; row++) {
    for (let column = 0; column < columns; column++) {
      const distance = signedDistance(column + 0.5 - BUFFER, row + 0.5 - BUFFER, polygon);
      bitmap[row * columns + column] = Math.max(0, Math.min(255, Math.round(255 - 255 * (distance / SDF_RADIUS + SDF_CUTOFF))));
    }
  }
  return { bitmap, width: Math.ceil(WIDTH), height: HEIGHT };
}

const varint = (value) => {
  const bytes = [];
  while (value > 127) {
    bytes.push((value & 127) | 128);
    value = Math.floor(value / 128);
  }
  bytes.push(value);
  return bytes;
};
const zigzag = (value) => (value < 0 ? -2 * value - 1 : 2 * value);
const number = (field, value) => [...varint(field << 3), ...varint(value)];
const bytes = (field, value) => [...varint((field << 3) | 2), ...varint(value.length), ...value];

/** The range file's bytes (glyphs.proto: glyphs > stacks > glyphs). */
export function chevronFontBytes() {
  const { bitmap, width, height } = chevronBitmap();
  const glyph = [
    ...number(1, CHEVRON_CODE_POINT),
    ...bytes(2, bitmap),
    ...number(3, width),
    ...number(4, height),
    ...number(5, zigzag(0)),
    ...number(6, zigzag(TOP)),
    ...number(7, ADVANCE),
  ];
  const encoder = new TextEncoder();
  const stack = [...bytes(1, encoder.encode(CHEVRON_FONT)), ...bytes(2, encoder.encode(CHEVRON_RANGE)), ...bytes(3, glyph)];
  return Uint8Array.from(bytes(1, stack));
}
