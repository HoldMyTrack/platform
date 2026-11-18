/**
 * Whether a client overlay's layers `ids` sit where they belong in the map's layer `order`: one
 * run, in their own order, right under `beforeId` (the first basemap label). A group the layers
 * document adds later goes in under that same label, so above them, and the overlay moves back
 * on the next `styledata`. Moving a layer fires `styledata` itself, so it moves only when this
 * says no, or it would loop. Undefined `beforeId`, a style with no labels, asks nothing.
 */
export function overlayInPlace(order: readonly string[], ids: readonly string[], beforeId: string | undefined): boolean {
  if (beforeId === undefined || ids.length === 0) return true;
  const at = order.indexOf(beforeId);
  if (at < ids.length) return false;
  return ids.every((id, i) => order[at - ids.length + i] === id);
}
