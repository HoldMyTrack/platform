/**
 * Whether a tap on the live map acts: selects a track, opens a spot or clears the focus. Off while
 * the export's viewfinder is open, so framing only pans and zooms (FR-4.10). Module-level like
 * tracks.ts's handlers: the map's listeners are attached once and read it on every click.
 */
let active = true;

export function setMapTapsActive(next: boolean): void {
  active = next;
}

export function mapTapsActive(): boolean {
  return active;
}
