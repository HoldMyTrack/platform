// Retakes the Play listing's raw phone captures on the Android emulator, signed in to production's demo.
// Usage, from the repository root, with the release build installed and signed in to the demo:
//   node brand/play/source/shoot.mjs <en|ru> [shot …]
// Writes brand/play/source/raw/<locale>/phone-<shot>.png; render.mjs then draws the callouts.
import { resolve, dirname } from "node:path";
import { mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { APP, shell, sleep, tap, tapView, drag, pinch, screenshot, demoStatusBar, exitDemoStatusBar, resetGeometry } from "./device.mjs";
import { restart, layers, mode, places, scrollTo, focusTrack } from "./app.mjs";

const here = dirname(fileURLToPath(import.meta.url));

// Every shot starts from a restart at the account's opening view, so its camera comes from the
// same pinches and drags each time. Coordinates are the screen's pixels at 1080×1920 and 420 dpi,
// tuned against the committed captures (README.md).
const MAP = [540, 800];

/** Where the profile's rows sit, per language: Month with the page 1000 px above its bottom, the
 *  places with the page at its bottom, and how far back up the shot is taken. */
const PROFILE = {
  en: { month: [281, 1154], italy: [158, 1392], lazio: [240, 1457], roma: [410, 1457], up: 380 },
  ru: { month: [319, 860], italy: [192, 1274], lazio: [250, 1397], roma: [408, 1399], up: 450 },
};

/** The Fog levels' labels, as the app shows them. */
const FOG = { en: { city: "City", exact: "Exact" }, ru: { city: "Город", exact: "Точно" } };

/** Beachwood, Ohio: beside the demo's captured playground and museum. */
const SPOTS_LOCATION = "41.4755,-81.4916";

function location(on) {
  for (const p of ["ACCESS_FINE_LOCATION", "ACCESS_COARSE_LOCATION"]) shell(`pm ${on ? "grant" : "revoke"} ${APP} android.permission.${p}`);
  if (!on) return;
  shell("appops set com.android.shell android:mock_location allow");
  shell("cmd location providers add-test-provider gps");
  shell("cmd location providers set-test-provider-enabled gps true");
  shell(`cmd location providers set-test-provider-location gps --location ${SPOTS_LOCATION} --accuracy 5`);
}

const SHOTS = {
  "01-map": async () => {
    await layers({ satellite: false, roads: true });
    await focusTrack("Lake to Lake Trail", MAP);
    await tapView("card_focus");
    await sleep(3000);
    // A third of a level closer than Zoom's fit, right of the callouts. Pinched low on the map,
    // where its zoom-out taps miss the photos.
    await pinch(540, 950, 0.85);
    await drag(300, 600, 150, 140);
    await sleep(1500);
  },
  "02-fog": async (locale) => {
    // Satellite under the cleared towns, Cleveland to Akron, Kent's popup open.
    await layers({ satellite: true, roads: true });
    await mode(FOG[locale].city);
    await pinch(...MAP, -3.0);
    await drag(800, 1000, -610, -50);
    await sleep(1500);
    await tap(770, 1160); // Kent
    await sleep(1500);
  },
  "03-fog-exact": async (locale) => {
    // Satellite along every cleared street, Cleveland down to Brecksville: 41 km east of the
    // opening view, in drags short enough not to fling.
    await layers({ satellite: true, roads: true });
    await mode(FOG[locale].exact);
    await pinch(...MAP, -1.34);
    for (let i = 0; i < 4; i++) {
      await drag(800, 1000, -576, 22);
      await sleep(600);
    }
  },
  "04-trip": async () => {
    await layers({ satellite: true, roads: true });
    await tapView("nav_trips");
    await sleep(3000);
    await tapView("tour_next", { optional: true, timeout: 2000 });
    await scrollTo("trips_list", (v) => v.id === "trip_toggle" && v.desc === "Greater Cleveland trails", { towards: "start" });
  },
  "05-spots": async () => {
    await layers({ satellite: false, roads: true });
    await places(true);
    location(true);
    await sleep(1000);
    await tapView("locate_button");
    await sleep(3000);
    // A fresh fix, or the dot greys out as a stale one.
    location(true);
    await sleep(2000);
  },
  "07-you": async () => {
    await tapView("nav_you");
    await sleep(3000);
  },
  "08-profile": async (locale) => {
    shell("cmd uimode night yes");
    await sleep(2000);
    await tapView("nav_you");
    await sleep(2000);
    await tapView((v) => /^(Track graph & trends|График и тренды)$/.test(v.text));
    await sleep(6000);
    await profilePlaces(PROFILE[locale]);
  },
};

/** The profile page scrolled to Explored places, with Italy open down to its towns, then `up` px
 *  back up so the trends' bars show above. The page is a WebView, which UI Automator doesn't see
 *  into, so each row is tapped where it sits once the page is at its bottom. */
async function profilePlaces({ month, italy, lazio, roma, up }) {
  const bottom = async () => {
    for (let i = 0; i < 4; i++) {
      shell("input swipe 540 1500 540 500 300");
      await sleep(500);
    }
    await sleep(800);
  };
  // Month first: choosing it reloads the page, which keeps what's open but scrolls to the top.
  // Then Italy, Lazio and Roma Capitale, each opening a row above the page's end.
  await bottom();
  await drag(540, 500, 0, 1000);
  await sleep(800);
  await tap(...month);
  await sleep(4000);
  for (const row of [italy, lazio, roma]) {
    await bottom();
    await tap(...row);
    await sleep(1500);
  }
  await bottom();
  await drag(540, 800, 0, up);
  await sleep(1000);
}

const [locale, ...only] = process.argv.slice(2);
if (!PROFILE[locale]) {
  console.error("usage: node brand/play/source/shoot.mjs <en|ru> [shot …]");
  process.exit(2);
}
const out = resolve(here, "raw", locale);
mkdirSync(out, { recursive: true });
shell("wm size 1080x1920");
shell("wm density 420");
resetGeometry();
shell(`cmd locale set-app-locales ${APP} --locales ${locale}`);
demoStatusBar();
try {
  for (const [name, steps] of Object.entries(SHOTS)) {
    if (only.length && !only.includes(name)) continue;
    shell("cmd uimode night no");
    location(false);
    await restart();
    await places(false);
    await mode();
    await steps(locale);
    await sleep(1500);
    screenshot(resolve(out, `phone-${name}.png`));
    console.log(`phone-${name}`);
  }
} finally {
  // The emulator as it was: no fake location, the app in the phone's language, the real screen.
  shell("cmd uimode night no");
  location(false);
  shell("cmd location providers remove-test-provider gps");
  shell("appops set com.android.shell android:mock_location default");
  shell(`cmd locale set-app-locales ${APP} --locales ""`);
  exitDemoStatusBar();
  shell("wm size reset");
  shell("wm density reset");
}
