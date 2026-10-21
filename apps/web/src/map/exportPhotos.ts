import type { PhotoMarkerPlacement } from './photoClusters';
import { PHOTO_MARKER_LOOK, type PhotoMarkerLookSize } from './photoMarkerLook';
import type { PhotoMarkerItem } from './photos';

/**
 * The photo markers on screen, drawn into an exported image (FR-4.10) after the map, under the
 * attribution and watermark. Where they go and how big is photoClusters.ts's photoMarkerLayout;
 * how they look is photoMarkerLook.ts and the theme's tokens, as index.css draws them live.
 */

/** The markers on screen when Capture was pressed (usePhotoLayer.ts). */
export interface ExportPhotos {
  items: readonly PhotoMarkerItem[];
  activeId: string | null;
  loneId: string | null;
}

interface MarkerColors {
  surface: string;
  tint: string;
  accent: string;
  onAccent: string;
  edge: string;
  font: string;
}

/** Draws [placements] onto [canvas]; [scale] is output pixels per CSS pixel. A thumbnail that
 *  fails to load leaves its frame empty; it never fails the export. */
export async function drawPhotoMarkers(
  canvas: HTMLCanvasElement,
  placements: readonly PhotoMarkerPlacement[],
  items: readonly PhotoMarkerItem[],
  scale: number,
): Promise<void> {
  if (placements.length === 0) return;
  const ctx = canvas.getContext('2d');
  if (!ctx) throw new Error('export: could not create photo marker canvas context');
  const byId = new Map(items.map((item) => [item.id, item]));
  const thumbs = await Promise.all(placements.map((m) => loadThumb(byId.get(m.ids[0]!)?.thumbSrc)));
  const colors = themeColors();
  placements.forEach((m, i) => drawMarker(ctx, m, thumbs[i] ?? null, scale, colors));
  for (const thumb of thumbs) thumb?.close();
}

/** Fetched, not an `<img>`: a cross-origin image drawn without CORS would taint the canvas, and
 *  `toBlob` would refuse it. Past the cache: the marker's `<img>` cached the same URL without
 *  the CORS headers (an API on another origin, as in dev), and the browser would reuse it. */
async function loadThumb(src: string | undefined): Promise<ImageBitmap | null> {
  if (!src) return null;
  try {
    const res = await fetch(src, { credentials: 'include', cache: 'reload' });
    if (!res.ok) return null;
    return await createImageBitmap(await res.blob());
  } catch {
    return null;
  }
}

function themeColors(): MarkerColors {
  const css = getComputedStyle(document.documentElement);
  const token = (name: string) => css.getPropertyValue(name).trim();
  return {
    surface: token('--fm-surface'),
    tint: token('--fm-surface-tint-strong'),
    accent: token('--fm-accent'),
    onAccent: token('--fm-on-accent'),
    edge: `rgb(${token('--fm-shadow-rgb')} / 25%)`,
    font: token('--fm-font-sans') || 'sans-serif',
  };
}

function drawMarker(
  ctx: CanvasRenderingContext2D,
  m: PhotoMarkerPlacement,
  thumb: ImageBitmap | null,
  scale: number,
  colors: MarkerColors,
): void {
  const look = PHOTO_MARKER_LOOK[m.small ? 'small' : 'full'];
  const r = m.diameter / 2;
  const border = (m.active ? look.activeBorder : look.border) * scale;
  const circle = (x: number, y: number, radius: number, fill: string) => {
    ctx.beginPath();
    ctx.arc(x, y, radius, 0, Math.PI * 2);
    ctx.fillStyle = fill;
    ctx.fill();
  };

  ctx.save();
  // Two cards behind a group, up and to the right, as the CSS's stacked box-shadows.
  if (m.ids.length > 1) {
    for (const step of [2, 1]) {
      const d = look.stack * step * scale;
      circle(m.x + d, m.y - d, r, colors.edge);
      circle(m.x + d, m.y - d, r - scale, colors.surface);
    }
  }
  // The frame's shadow, close to --fm-shadow-md.
  ctx.shadowColor = 'rgb(0 0 0 / 22%)';
  ctx.shadowBlur = 10 * scale;
  ctx.shadowOffsetY = 2 * scale;
  circle(m.x, m.y, r, m.active ? colors.accent : colors.surface);
  ctx.shadowColor = 'transparent';
  const inner = r - border;
  circle(m.x, m.y, inner, colors.tint);
  if (thumb) {
    ctx.save();
    ctx.beginPath();
    ctx.arc(m.x, m.y, inner, 0, Math.PI * 2);
    ctx.clip();
    // object-fit: cover.
    const side = Math.min(thumb.width, thumb.height);
    ctx.drawImage(thumb, (thumb.width - side) / 2, (thumb.height - side) / 2, side, side, m.x - inner, m.y - inner, inner * 2, inner * 2);
    ctx.restore();
  }
  if (m.ids.length > 1) drawCount(ctx, m, look, border, scale, colors);
  ctx.restore();
}

/** The count's pill on the circle's top-right corner, as `.photo-marker__count`, whose offsets
 *  are from inside the ring. */
function drawCount(
  ctx: CanvasRenderingContext2D,
  m: PhotoMarkerPlacement,
  look: PhotoMarkerLookSize,
  border: number,
  scale: number,
  colors: MarkerColors,
): void {
  const text = String(m.ids.length);
  const r = m.diameter / 2 - border;
  const h = look.countHeight * scale;
  ctx.font = `700 ${look.countFont * scale}px ${colors.font}`;
  const w = Math.max(h, ctx.measureText(text).width + 2 * look.countPad * scale);
  const right = m.x + r + look.countRight * scale;
  const top = m.y - r - look.countTop * scale;
  ctx.beginPath();
  ctx.roundRect(right - w, top, w, h, h / 2);
  ctx.fillStyle = colors.accent;
  ctx.fill();
  ctx.fillStyle = colors.onAccent;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillText(text, right - w / 2, top + h / 2);
}
