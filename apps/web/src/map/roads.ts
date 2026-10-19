/**
 * The layers the Layers menu's Roads (FR-4.17, overlays.ts) shows and hides: every basemap layer
 * named `roads_*` — the lines with their casings,
 * bridges, tunnels, rail and one-way arrows, and the street names and shields that would
 * otherwise float over nothing. The trails (`paths_*`) and place labels stay.
 */
export function roadLayerIds(layers: readonly { id: string; source?: unknown }[], basemapSource: string): string[] {
  return layers.filter((layer) => layer.source === basemapSource && layer.id.startsWith('roads_')).map((layer) => layer.id);
}