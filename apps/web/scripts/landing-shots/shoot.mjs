// Retakes the About page's screenshots on production; README.md says how to run it and why it
// works the way it does.
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { firefox } from 'playwright';
import { MAX_WHEEL_STEP, cameraFromHash, dragSplit, panOffset, wheelDelta } from './camera.mjs';

const SITE = 'https://holdmytrack.com';
const OUT = fileURLToPath(new URL('../../../../services/server/internal/web/static/landing/', import.meta.url));
const VIEWPORT = { width: 1728, height: 974 };
const SIZE = ['1760', '992'];
const QUALITY = '80';
const PLACES = ['Mesmerizing views', 'Waterfalls', 'Historic sites'];
/** What a slide must never show: the tour, its offer and first-use cards, and the demo bar. */
const OVERLAYS = ['tour', 'tour-offer', 'tour-card', 'demo-bar'];
/** Where the tunnel photo's marker sits on the track slide, once steered and turned. */
const TUNNEL_PHOTO = { x: 1381, y: 587 };

/** Each slide: the URL it opens and what it does there before the shot. */
const SLIDES = {
  map: {
    url: '/#map=10.98/41.4474/-81.6404',
    async run(page) {
      await pickPlaces(page);
      await page.getByRole('checkbox', { name: 'Check Evening loop' }).check();
      await page.getByRole('checkbox', { name: 'Check Oct 3, 2026, 12:46 PM' }).check();
      // Focusing a track flies the camera to it, so the view is set again after.
      await page.getByText('Oct 4, 2026, 03:18 PM', { exact: true }).click();
      await page.waitForTimeout(2500);
      await steer(page, { zoom: 10.98, lat: 41.4474, lon: -81.6404 });
      await page.getByRole('button', { name: 'Show places in this area' }).click();
    },
  },
  trip: {
    url: '/#map=10.84/41.4238/-81.6337',
    async run(page) {
      await pickPlaces(page);
      await page.locator('[data-testid=map-places] input[type=checkbox]').uncheck();
      await page.getByRole('tab', { name: 'Trips' }).click();
      await page.waitForTimeout(2500);
      // The Trips tab's first-use card, when this browser hasn't closed it yet.
      await page.getByTestId('tour-card-close').click({ timeout: 3000 }).catch(() => {});
      await steer(page, { zoom: 10.84, lat: 41.4238, lon: -81.6337 });
    },
  },
  track: {
    url: '/#map=11/41.431/-81.641',
    async run(page) {
      await pickPlaces(page);
      await page.getByRole('button', { name: 'Satellite', exact: true }).click();
      await page.getByText('Lake to Lake Trail', { exact: true }).click();
      await page.waitForTimeout(3000);
      await steer(page, { zoom: 14.48, lat: 41.36756, lon: -81.83282 });
      await rotate(page, -57); // about 45° counterclockwise; the hash does not carry the bearing
      await openPhotoAt(page, TUNNEL_PHOTO);
    },
  },
  profile: {
    url: '/profile',
    async run(page) {
      // The stat cards 7.85 CSS px below the top, as in the original.
      await page.evaluate(() => {
        let e = [...document.querySelectorAll('body *')].find((n) => n.children.length === 0 && /^longest streak$/i.test(n.textContent.trim()));
        while (e && e.getBoundingClientRect().width < 900) e = e.parentElement;
        window.scrollTo(0, window.scrollY + e.getBoundingClientRect().top - 7.85);
      });
    },
  },
};

async function pickPlaces(page) {
  await page.locator('[data-testid=map-places] button:has-text("Places")').click();
  for (const name of PLACES) await page.getByText(name, { exact: true }).click();
  await page.keyboard.press('Escape');
  await page.waitForTimeout(1000);
}

/** Clicks the photo marker at point, failing when there is none, or a group's is there instead: a
 *  click on the map would clear the focused track and still be shot. */
async function openPhotoAt(page, point) {
  const found = await page.evaluate(({ x, y }) => {
    const marker = document.elementFromPoint(x, y)?.closest('.photo-marker');
    return !!marker && !marker.classList.contains('photo-marker--group');
  }, point);
  if (!found) throw new Error(`no photo marker at ${point.x},${point.y}; set TUNNEL_PHOTO from a trial shot`);
  await page.mouse.click(point.x, point.y);
  await page.getByTestId('photo-popup').waitFor({ timeout: 5000 });
}

/** Fails when an overlay a slide must not show is on screen: the clicks that close them pass
 *  over a prompt that isn't there, so a renamed or moved one would otherwise be shot. */
async function assertNoOverlay(page) {
  for (const id of OVERLAYS) {
    if (await page.getByTestId(id).isVisible()) throw new Error(`${id} is on screen`);
  }
}

async function mapCentre(page) {
  const box = await page.locator('.maplibregl-canvas').boundingBox();
  return { x: box.x + box.width / 2, y: box.y + box.height / 2 };
}

/** Wheel and drag the map until the URL hash reports target, within a pixel. */
async function steer(page, target) {
  const c = await mapCentre(page);
  for (let i = 0; i < 12; i++) {
    const now = cameraFromHash(await page.evaluate(() => location.hash));
    const dz = target.zoom - now.zoom;
    if (Math.abs(dz) > 0.004) {
      await page.mouse.move(c.x, c.y);
      await page.mouse.wheel(0, wheelDelta(Math.max(-MAX_WHEEL_STEP, Math.min(MAX_WHEEL_STEP, dz))));
      await page.waitForTimeout(900);
      continue;
    }
    const { x, y } = panOffset(now, target);
    if (Math.abs(x) < 1 && Math.abs(y) < 1) return;
    for (const [mx, my] of dragSplit(x, y)) await drag(page, c, mx, my);
  }
  throw new Error(`camera did not reach ${JSON.stringify(target)}`);
}

async function drag(page, from, dx, dy, button = 'left') {
  await page.mouse.move(from.x, from.y);
  await page.mouse.down({ button });
  await page.mouse.move(from.x + dx, from.y + dy, { steps: 20 });
  await page.waitForTimeout(400); // still before release, so no inertia
  await page.mouse.up({ button });
  await page.waitForTimeout(700);
}

/** Right-drag sideways: MapLibre turns 0.8° per pixel. */
async function rotate(page, dx) {
  await drag(page, await mapCentre(page), dx, 0, 'right');
}

async function signIn(browser, statePath) {
  // English, as the shots are: /about and the tour follow the browser's language.
  const ctx = await browser.newContext({ viewport: VIEWPORT, locale: 'en-US', timezoneId: 'America/New_York' });
  const page = await ctx.newPage();
  await page.goto(`${SITE}/about`);
  await Promise.all([page.waitForURL((u) => !u.pathname.startsWith('/about')), page.locator('form[action="/demo"] button').first().click()]);
  if (new URL(page.url()).pathname !== '/') throw new Error(`demo sign-in failed at ${page.url()} (5 an hour per address)`);
  await page.getByTestId('tour-skip').click({ timeout: 15000 }).catch(() => {});
  await page.locator('.demo-bar__hide').click({ timeout: 5000 }).catch(() => {});
  await assertNoOverlay(page);
  await ctx.storageState({ path: statePath });
  await ctx.close();
}

async function shoot(browser, statePath, name, theme, png) {
  const slide = SLIDES[name];
  const ctx = await browser.newContext({
    viewport: VIEWPORT,
    deviceScaleFactor: 2,
    colorScheme: theme,
    storageState: statePath,
    locale: 'en-US',
    timezoneId: 'America/New_York',
  });
  const page = await ctx.newPage();
  await page.goto(SITE + slide.url);
  await page.waitForTimeout(3000);
  await slide.run(page);
  await page.waitForTimeout(4000); // tiles and photos
  await assertNoOverlay(page);
  await page.screenshot({ path: png });
  await ctx.close();
}

const names = process.argv.slice(2);
for (const n of names) if (!SLIDES[n]) throw new Error(`unknown slide ${n}; known: ${Object.keys(SLIDES).join(' ')}`);
const work = mkdtempSync(join(tmpdir(), 'landing-shots-'));
const browser = await firefox.launch();
try {
  const statePath = join(work, 'state.json');
  await signIn(browser, statePath);
  for (const name of names.length ? names : Object.keys(SLIDES)) {
    for (const theme of ['light', 'dark']) {
      const file = theme === 'dark' ? `${name}-dark` : name;
      const png = join(work, `${file}.png`);
      await shoot(browser, statePath, name, theme, png);
      execFileSync('cwebp', ['-quiet', '-q', QUALITY, '-resize', ...SIZE, png, '-o', join(OUT, `${file}.webp`)]);
      console.log(`${file}.webp`);
    }
  }
} finally {
  await browser.close();
  rmSync(work, { recursive: true, force: true });
}