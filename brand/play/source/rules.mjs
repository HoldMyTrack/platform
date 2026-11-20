// What shoot.mjs decides, as values in and values out; tested in apps/web/tests/playShots.test.mjs.

/** Where screen pixel (x, y) lands on the touch panel's 0–32767 axes. The panel is `pw`×`ph`; a
 *  `wm size` override of `w`×`h` is scaled to fit it and centred, so the panel's edges are
 *  letterbox, not screen. */
export function toPanel({ pw, ph, w, h }, x, y) {
  const s = Math.min(pw / w, ph / h);
  const ox = (pw - w * s) / 2;
  const oy = (ph - h * s) / 2;
  return [Math.round(((ox + x * s) / pw) * 32767), Math.round(((oy + y * s) / ph) * 32767)];
}

/** How to zoom by `levels` (fractional, negative to zoom out): a pinch of 2 to 3 levels either
 *  way, then `outTaps` two-finger taps of one level out or `inTaps` double taps of one level in.
 *  The map ignores a pinch whose fingers' spread changes by less than about 720 px, so a smaller
 *  zoom is a bigger pinch taken back by taps. */
export function zoomPlan(levels) {
  if (!Number.isFinite(levels)) throw new Error(`zoom of ${levels} levels`);
  if (levels > 3) {
    const inTaps = Math.ceil(levels - 3);
    return { pinch: levels - inTaps, outTaps: 0, inTaps };
  }
  for (let outTaps = 0; ; outTaps++) {
    const p = levels + outTaps;
    if ((p >= 2 && p <= 3) || (p <= -2 && p >= -3)) return { pinch: p, outTaps, inTaps: 0 };
  }
}

/** The Fog level menu's radio labelled `label`; the Auto row's text goes on with its hint. */
export function fogRadio(views, label) {
  return views.find((v) => v.id === "fog_level_radio" && (v.text === label || v.text.startsWith(`${label} `)));
}

/** Whether the Tracks or Trips panel is expanded: only then is its list on screen. */
export const panelExpanded = (views) => views.some((v) => v.id === "panel_list" || v.id === "trips_list");
