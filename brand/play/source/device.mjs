// Drives the Android emulator for shoot.mjs: adb, the screen's geometry, taps and multi-finger
// gestures, and finding a view by its id or text in a UI Automator dump.
import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { toPanel, zoomPlan } from "./rules.mjs";

const SDK = process.env.ANDROID_HOME ?? "/opt/homebrew/share/android-commandlinetools";
const ADB = `${SDK}/platform-tools/adb`;
export const APP = "dev.holdmytrack.android";

export const adb = (...args) => execFileSync(ADB, args, { encoding: "utf8", maxBuffer: 64 << 20 });
export const shell = (cmd) => adb("shell", cmd);
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** The emulator's panel and the size the screen is overridden to (`wm size`), in pixels. */
export function geometry() {
  const out = shell("wm size");
  const [pw, ph] = out.match(/Physical size: (\d+)x(\d+)/).slice(1).map(Number);
  const o = out.match(/Override size: (\d+)x(\d+)/);
  const [w, h] = o ? o.slice(1).map(Number) : [pw, ph];
  return { pw, ph, w, h };
}

let geo;
let trackingId = 100;
const emu = (...events) => adb("emu", "event", "send", ...events);

/** Puts fingers down at [[x, y], …], moves them through `path` (one [[x, y], …] per step), lifts
 *  them. Each finger rests 300 ms before lifting, so a drag ends without a fling. */
export async function gesture(start, path = [], { hold = 300 } = {}) {
  geo ??= geometry();
  const ids = start.map(() => trackingId++);
  const at = (pts) =>
    pts.flatMap(([x, y], i) => {
      const [px, py] = toPanel(geo, x, y);
      return [`EV_ABS:ABS_MT_SLOT:${i}`, `EV_ABS:ABS_MT_POSITION_X:${px}`, `EV_ABS:ABS_MT_POSITION_Y:${py}`];
    });
  emu(
    ...start.flatMap((_, i) => [`EV_ABS:ABS_MT_SLOT:${i}`, `EV_ABS:ABS_MT_TRACKING_ID:${ids[i]}`, "EV_ABS:ABS_MT_TOUCH_MAJOR:5", "EV_ABS:ABS_MT_PRESSURE:100"]),
    ...at(start),
    "EV_KEY:BTN_TOUCH:1",
    "EV_SYN:0:0",
  );
  for (const pts of path) {
    emu(...at(pts), "EV_SYN:0:0");
    await sleep(16);
  }
  if (path.length) await sleep(hold);
  emu(...start.flatMap((_, i) => [`EV_ABS:ABS_MT_SLOT:${i}`, "EV_ABS:ABS_MT_PRESSURE:0", "EV_ABS:ABS_MT_TRACKING_ID:-1"]), "EV_KEY:BTN_TOUCH:0", "EV_SYN:0:0");
}

/** Forgets the cached geometry; call after changing the screen's size or orientation. */
export const resetGeometry = () => (geo = undefined);

const lerp = (a, b, t) => a + (b - a) * t;
const steps = (n) => Array.from({ length: n }, (_, i) => (i + 1) / n);

/** Moves the map by (dx, dy) screen pixels: one finger, slow, resting before it lifts. */
export const drag = (x, y, dx, dy, n = 20) => gesture([[x, y]], steps(n).map((t) => [[x + dx * t, y + dy * t]]));

/** Map zoom in by one level about (x, y): a double tap. */
export async function zoomIn(x, y) {
  await gesture([[x, y]]);
  await sleep(60);
  await gesture([[x, y]]);
  await sleep(700);
}

/** Map zoom out by one level about the midpoint: a two-finger tap. */
export async function zoomOut(x, y) {
  await gesture([[x - 120, y], [x + 120, y]]);
  await sleep(700);
}

/** Map zoom by `levels` about (x, y); see zoomPlan. The fingers move along the horizontal, at
 *  most 1000 px apart, and rest before they lift so the map doesn't fling. */
export async function pinch(x, y, levels, n = 30) {
  const plan = zoomPlan(levels);
  const wide = 500;
  const narrow = wide / 2 ** Math.abs(plan.pinch);
  const [r0, r1] = plan.pinch > 0 ? [narrow, wide] : [wide, narrow];
  await gesture(
    [[x - r0, y], [x + r0, y]],
    steps(n).map((t) => {
      const r = lerp(r0, r1, t);
      return [[x - r, y], [x + r, y]];
    }),
    { hold: 500 },
  );
  await sleep(700);
  for (let i = 0; i < plan.outTaps; i++) await zoomOut(x, y);
  for (let i = 0; i < plan.inTaps; i++) await zoomIn(x, y);
}

export const tap = async (x, y) => {
  shell(`input tap ${Math.round(x)} ${Math.round(y)}`);
  await sleep(400);
};

/** The views on screen: id (without the package), text, content-desc and bounds' centre. */
export function views() {
  shell("uiautomator dump /sdcard/hmt-ui.xml >/dev/null");
  const xml = adb("exec-out", "cat /sdcard/hmt-ui.xml");
  const unescape = (s) => s.replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&").replace(/&#10;/g, "\n");
  return [...xml.matchAll(/<node ([^>]*?)\/?>/g)].map(([, attrs]) => {
    const a = Object.fromEntries([...attrs.matchAll(/([\w-]+)="([^"]*)"/g)].map(([, k, v]) => [k, unescape(v)]));
    const [x0, y0, x1, y1] = a.bounds.match(/\d+/g).map(Number);
    return { id: a["resource-id"].replace(`${APP}:id/`, ""), text: a.text, desc: a["content-desc"], x0, y0, x1, y1, x: (x0 + x1) / 2, y: (y0 + y1) / 2, checked: a.checked === "true", selected: a.selected === "true" };
  });
}

const matches = (v, q) =>
  typeof q === "string" ? v.id === q || v.text === q || v.desc === q : q instanceof RegExp ? q.test(v.text) || q.test(v.desc) : q(v);

/** The first view matching `q` (an id, an exact text or content-desc, a RegExp over either, or a
 *  predicate), waiting up to `timeout` ms for it to appear. */
export async function find(q, { timeout = 15000, optional = false } = {}) {
  const end = Date.now() + timeout;
  for (;;) {
    const v = views().find((v) => matches(v, q));
    if (v) return v;
    if (Date.now() > end) {
      if (optional) return null;
      throw new Error(`no view matches ${q}`);
    }
    await sleep(500);
  }
}

export async function tapView(q, opts) {
  const v = await find(q, opts);
  if (v) await tap(v.x, v.y);
  return v;
}

export function screenshot(path) {
  writeFileSync(path, execFileSync(ADB, ["exec-out", "screencap", "-p"], { maxBuffer: 64 << 20 }));
}

/** Leaves SystemUI's demo mode. */
export const exitDemoStatusBar = () => shell("am broadcast -a com.android.systemui.demo -e command exit >/dev/null");

/** A still status bar: 9:30, full Wi-Fi and battery, no notifications. */
export function demoStatusBar() {
  shell("settings put global sysui_demo_allowed 1");
  const demo = (args) => shell(`am broadcast -a com.android.systemui.demo -e command ${args} >/dev/null`);
  // Leaving first clears the icons an earlier run added; each network command adds one more.
  demo("exit");
  demo("enter");
  demo("clock -e hhmm 0930");
  demo("battery -e level 100 -e plugged false -e powersave false");
  demo("network -e wifi show -e level 4 -e fully true -e mobile hide");
  demo("notifications -e visible false");
}
