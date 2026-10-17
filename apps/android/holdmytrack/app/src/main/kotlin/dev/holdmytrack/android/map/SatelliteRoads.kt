package dev.holdmytrack.android.map

/**
 * Whether the basemap's roads come off the map: over satellite imagery in Fog and Heatmap. There
 * the picture is the ground and what the user covered of it; Normal keeps the roads, see-through,
 * as the way through the imagery. The web's `roadsHiddenOverImagery`; both run
 * `testdata/client-rules/satellite-roads.json`.
 */
fun roadsHiddenOverImagery(satellite: Boolean, mode: MapMode): Boolean = satellite && mode != MapMode.NORMAL
