/**
 * The photo viewer's zoom and pan (PhotoViewer.tsx), as plain math over a view: the
 * picture fitted to the stage and centered is scale 1 at (0, 0); `scale` multiplies that and
 * `x`/`y` move its center, in CSS pixels from the stage's center. Android's `PhotoZoom.kt` runs
 * the same cases, `testdata/client-rules/photo-fit.json`, `photo-zoom.json`, `photo-pan.json` and
 * `photo-clamp.json`.
 */
export interface ZoomView {
  scale: number;
  x: number;
  y: number;
}

export interface Size {
  width: number;
  height: number;
}

export const FIT_VIEW: ZoomView = { scale: 1, x: 0, y: 0 };
/** Past this the 2048 px stored copy is only blur on a typical screen. */
export const MAX_SCALE = 8;
/** One press of + or −. */
export const ZOOM_STEP = 1.5;
/** Where a double-click on the fitted picture zooms to. */
export const DOUBLE_CLICK_SCALE = 3;

/** The picture's size at scale 1: as large as fits the stage, never larger than it is. */
export function fitSize(image: Size, stage: Size): Size {
  if (image.width <= 0 || image.height <= 0) return { width: 0, height: 0 };
  const ratio = Math.min(stage.width / image.width, stage.height / image.height, 1);
  return { width: image.width * ratio, height: image.height * ratio };
}

/**
 * Holds the picture where it can be: no smaller than fitted, no larger than MAX_SCALE, and an
 * edge never pulled in past the stage's edge — a picture narrower than the stage stays centered.
 */
export function clampView(view: ZoomView, fitted: Size, stage: Size): ZoomView {
  const scale = Math.min(Math.max(view.scale, 1), MAX_SCALE);
  const maxX = Math.max(0, (fitted.width * scale - stage.width) / 2);
  const maxY = Math.max(0, (fitted.height * scale - stage.height) / 2);
  return { scale, x: clamp(view.x, maxX), y: clamp(view.y, maxY) };
}

/**
 * Scales by `factor` about `point` (from the stage's center), so what's under the pointer — or
 * between the fingers — stays there.
 */
export function zoomAt(view: ZoomView, factor: number, point: { x: number; y: number }, fitted: Size, stage: Size): ZoomView {
  const scale = Math.min(Math.max(view.scale * factor, 1), MAX_SCALE);
  const k = scale / view.scale;
  return clampView({ scale, x: point.x - (point.x - view.x) * k, y: point.y - (point.y - view.y) * k }, fitted, stage);
}

export function panBy(view: ZoomView, dx: number, dy: number, fitted: Size, stage: Size): ZoomView {
  return clampView({ ...view, x: view.x + dx, y: view.y + dy }, fitted, stage);
}

function clamp(value: number, limit: number): number {
  // + 0 turns a -0 into 0, so a view that hasn't moved compares equal to FIT_VIEW.
  return Math.min(Math.max(value, -limit), limit) + 0;
}

/** How far one arrow key pans a zoomed photo, in screen pixels. */
export const PAN_STEP = 80;

/** What an arrow key does in the photo viewer: steps between photos while the photo fits, and
 *  pans it while zoomed, where the arrows would otherwise leave the keyboard no way to look
 *  around. The pan moves the photo, so ArrowLeft brings its left side into view. */
export function arrowKeyAction(key: string, zoomed: boolean): { pan: { dx: number; dy: number } } | 'previous' | 'next' | null {
  if (zoomed) {
    switch (key) {
      case 'ArrowLeft':
        return { pan: { dx: PAN_STEP, dy: 0 } };
      case 'ArrowRight':
        return { pan: { dx: -PAN_STEP, dy: 0 } };
      case 'ArrowUp':
        return { pan: { dx: 0, dy: PAN_STEP } };
      case 'ArrowDown':
        return { pan: { dx: 0, dy: -PAN_STEP } };
      default:
        return null;
    }
  }
  if (key === 'ArrowLeft') return 'previous';
  if (key === 'ArrowRight') return 'next';
  return null;
}
