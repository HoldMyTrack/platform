/**
 * The map image export's stats card (FR-4.7, `IMPLEMENTATION.md` §4.3.3): when it's offered, what
 * the server is asked to draw, and where the drawn card goes. The server renders the card; the
 * client only places it, in the bottom-left corner above the watermark, sharing the lower strip's
 * sizing with the credit and the watermark (`exportMap.ts`).
 */

/** Attribution font size, as a fraction of the final canvas's shorter side, clamped so it never
 *  disappears on a small export or overwhelms the largest. */
const ATTRIBUTION_FONT_FRACTION = 0.016;
const ATTRIBUTION_MIN_FONT_PX = 12;
const ATTRIBUTION_MAX_FONT_PX = 28;
/** Distance from the canvas's corners to the strip, the same fraction-of-shorter-side scaling. */
const ATTRIBUTION_MARGIN_FRACTION = 0.014;

/** The watermark's wordmark font size, relative to the attribution's: the two share one strip. */
export const WATERMARK_FONT_SCALE = 1.15;
/** The logo glyph's height, as a multiple of the wordmark's font size. */
export const WATERMARK_LOGO_SCALE = 1.7;

/** The lower strip's shared sizing: the attribution font size and the corner margin. */
export function stripMetrics(width: number, height: number): { fontPx: number; margin: number } {
  const shortSide = Math.min(width, height);
  const fontPx = Math.min(ATTRIBUTION_MAX_FONT_PX, Math.max(ATTRIBUTION_MIN_FONT_PX, shortSide * ATTRIBUTION_FONT_FRACTION));
  const margin = Math.max(fontPx * 0.5, shortSide * ATTRIBUTION_MARGIN_FRACTION);
  return { fontPx, margin };
}

/**
 * Whether Show stats can be ticked: with something checked in the Activities panel, and no Story
 * open, since the Stories tab has no checkboxes.
 */
export function statsOffered(checked: Iterable<string>, storyId: string | null): boolean {
  if (storyId !== null) return false;
  for (const _ of checked) return true;
  return false;
}

export interface StatsCardRequest {
  activityIds: string[];
  width: number;
  height: number;
  theme: 'light' | 'dark';
}

/** What the server is asked to draw for an image `size`, or null when no card is shown. The ids
 *  are sorted so the same checked set is the same request. */
export function statsCardRequest(
  show: boolean,
  checked: Iterable<string>,
  storyId: string | null,
  size: { widthPx: number; heightPx: number },
  dark: boolean,
): StatsCardRequest | null {
  if (!show || !statsOffered(checked, storyId)) return null;
  return { activityIds: [...checked].sort(), width: size.widthPx, height: size.heightPx, theme: dark ? 'dark' : 'light' };
}

/** A request as a string, equal for equal requests: what the held card is checked against. */
export function statsCardKey(request: StatsCardRequest | null): string {
  return request ? `${request.width}x${request.height}:${request.theme}:${request.activityIds.join(',')}` : '';
}

/**
 * Where a card `card` px in size goes on an image `width` × `height`: at the strip's left margin,
 * a margin above the watermark's top. The watermark's bottom is the credit plate's, taken at its
 * nominal descent so the preview and the image agree without measuring text. Never above the top
 * margin.
 */
export function statsCardPlacement(width: number, height: number, card: { width: number; height: number }): { x: number; y: number } {
  const { fontPx, margin } = stripMetrics(width, height);
  // drawAttribution's plate: its baseline a margin up, then the descent and padding below it.
  const stripBottom = height - margin + fontPx * 0.2 + fontPx * 0.3;
  const watermarkFont = fontPx * WATERMARK_FONT_SCALE;
  const watermarkTop = stripBottom - Math.max(watermarkFont * WATERMARK_LOGO_SCALE, watermarkFont);
  return { x: margin, y: Math.max(margin, watermarkTop - margin - card.height) };
}