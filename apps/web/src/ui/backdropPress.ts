/** A dialog's box as `getBoundingClientRect` gives it. */
export interface Box {
  left: number;
  right: number;
  top: number;
  bottom: number;
}

/**
 * Whether a press at (x, y) on the `<dialog>` element itself fell on its backdrop. The target
 * alone doesn't tell: the `<dialog>` is also the target of a press on its own padding.
 */
export function onBackdrop(targetIsDialog: boolean, box: Box, x: number, y: number): boolean {
  return targetIsDialog && (x < box.left || x > box.right || y < box.top || y > box.bottom);
}
