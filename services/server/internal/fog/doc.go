// Package fog implements IMPLEMENTATION.md §4.2's precomputed raster coverage mask, §4.1 steps 4
// (the rendering half; dirty-marking lives in internal/ingest, which has raw points in memory
// already) and 7 (re-rendering dirty tiles).
//
// # Tile size
//
// Masks and tiles are 128 px (TileSize), the same so compositing needs no resampling. At 512 px
// pixels were most of a render's work and bytes for little visible gain; 64 px merges nearby
// tracks from z13 out; 256 px doubles the mask bytes for detail finer than GPS.
//
// # Rendering
//
// Storing a tile marks its parent dirty in the same transaction. RenderUser renders z14 and then
// each level up, starting a level only once the one below is stored, so a pass cut off leaves
// parents dirty for the next. A render is mostly object-store round trips, so it runs them side
// by side (PERFORMANCE.md, 2026-10-08).
package fog
