// The app's own controls for shoot.mjs: start it on the map, and set the map's mode and layers.
import { APP, shell, sleep, find, tapView, views, tap, zoomOut } from "./device.mjs";
import { fogRadio, panelExpanded } from "./rules.mjs";

/** Starts the app afresh on the Tracks tab, at the account's opening view. */
export async function restart() {
  shell(`am force-stop ${APP}`);
  shell(`am start -n ${APP}/.MainActivity`);
  await find("mode_fog", { timeout: 60000 });
  await sleep(5000);
}

/** Places on with every category, or off. */
export async function places(on) {
  await tapView("places_button");
  await setChecked("places_master", on);
  if (on) for (const id of PLACE_CATEGORIES) await setChecked(id, true);
  shell("input keyevent 4");
  await sleep(800);
}
const PLACE_CATEGORIES = ["places_playground", "places_dog_park", "places_monument", "places_viewpoint", "places_waterfall", "places_history"];

export async function expandPanel(on = true) {
  if (panelExpanded(views()) !== on) await tapView("panel_handle");
  await sleep(1200);
}

/** Scrolls the panel's list (by id) until `q` shows whole inside it; the views' bounds say how
 *  far. `towards` is where the row is while it's off the list: "end" below, "start" above. */
export async function scrollTo(listId, q, { towards = "end", timeout = 20 } = {}) {
  for (let i = 0; i < timeout; i++) {
    const vs = views();
    const list = vs.find((v) => v.id === listId);
    if (!list) {
      // The tab may still be loading.
      await sleep(1000);
      continue;
    }
    const v = vs.find((v) => matches(v, q));
    if (v && v.y0 >= list.y0 && v.y1 <= list.y1) return v;
    // Back towards the start when the row is cut off at the top or above the list.
    const down = v ? v.y0 < list.y0 : towards === "start";
    const span = Math.min(list.y1 - list.y0 - 40, v ? Math.abs(v.y0 - list.y0) + 20 : 400);
    const [from, to] = down ? [list.y0 + 20, list.y0 + 20 + span] : [list.y1 - 20, list.y1 - 20 - span];
    shell(`input swipe ${Math.round(list.x)} ${from} ${Math.round(list.x)} ${to} 600`);
    await sleep(700);
  }
  throw new Error(`no ${q} in ${listId}, or no ${listId} on screen`);
}

const matches = (v, q) => (typeof q === "function" ? q(v) : v.id === q || v.text === q || v.desc === q);

/** Focuses the track titled `title`: zooms out to every track, finds it in the list, taps it. */
export async function focusTrack(title, [mapX, mapY]) {
  await expandPanel(false);
  for (let i = 0; i < 4; i++) await zoomOut(mapX, mapY);
  await expandPanel(true);
  const row = await scrollTo("panel_list", title);
  await tap(row.x, row.y);
  await sleep(3000);
}

/** Sets a switch or checkbox by id to `on`. */
export async function setChecked(id, on) {
  const v = await find(id);
  if (v.checked !== on) await tap(v.x, v.y);
}

/** Satellite and Roads as given, with the layers panel closed again. */
export async function layers({ satellite, roads }) {
  await tapView("layers_button");
  await setChecked("layers_satellite", satellite);
  await setChecked("layers_roads", roads);
  shell("input keyevent 4");
  await sleep(800);
}

/** Normal, or Fog at the level labelled `label` in the app's language. */
export async function mode(label) {
  if (!label) return tapView("mode_normal");
  await tapView("mode_fog");
  await sleep(1000);
  if (!views().some((v) => v.id === "fog_level_radio")) await tapView("mode_fog");
  const r = fogRadio(views(), label);
  if (!r) throw new Error(`no Fog level labelled ${label}`);
  await tap(r.x, r.y);
  await sleep(1500);
}
